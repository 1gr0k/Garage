# Этап 6b: сервер синхронизации (`Server/`, Vapor)

## Контекст
Контракт API v1 описан в `docs/api.md`, DTO лежат в `Packages/GarageAPI` (этап 6a). Нужен сервер, который реализует контракт целиком: регистрацию устройств и токены, push/pull с версиями и tombstones, идемпотентность по `changeID` и чеки по sha256. Сервер — отдельный SwiftPM-пакет, в Xcode-проект он не подключается. Корневой `CLAUDE.md` и всё вне `Server/` не трогаю. Исключение — план в `docs/plans/stage-6b-server.md`: его прямо просил пользователь, и он записывается первым шагом. Если контракт кажется неверным, я его не меняю, а записываю вопрос в отчёт.

Решение пользователя: сервер зависит от `GarageAPI` **и** `GarageCore`. Содержимое DTO проверяется через валидирующие init доменных типов, поэтому правила хранятся в одном месте.

## Первый шаг реализации
1. Влить `master` с обновлённым контрактом (`4f5e732`: идемпотентное удаление, каскадные tombstones, один экземпляр процесса).
2. Сохранить этот план в `docs/plans/stage-6b-server.md`.

## Пакет `Server/Package.swift`
- swift-tools 6.0, `.macOS(.v15)`, Swift 6 language mode.
- Зависимости: `vapor` 4.x (с продуктом `VaporTesting` для Swift Testing), `fluent` 4.x, `fluent-sqlite-driver` 4.x, `swift-crypto` (`Crypto`: SHA-256, случайные байты; не CryptoKit, ради Linux), `.package(path: "../Packages/GarageAPI")`, `.package(path: "../Packages/GarageCore")`.
- Цели: `executableTarget GarageServer` (только `main.swift` с entrypoint), `target App` (вся логика), `testTarget AppTests` (зависит от `App` и `VaporTesting`).
- `Package.resolved` коммитится. `.build/` уже есть в корневом `.gitignore`.

## Конфигурация (`configure.swift`)
- `GARAGE_DB_PATH` — путь к SQLite-файлу (обязателен, кроме тестов: там `.sqlite(.memory)`).
- `GARAGE_SETUP_SECRET` — секрет регистрации, обязателен. Без него старт падает с понятной ошибкой. Сравнение — в постоянное время по SHA-256-дайджестам.
- Кодеры Vapor заменяются на `APICoding.makeEncoder()/makeDecoder()` (`ContentConfiguration.global.use(...)` для `.json`).
- Лимит тела: `routes.defaultMaxBodySize` для JSON. Для `PUT /v1/receipts` — `body: .collect(maxSize: 5 MiB + 1)` с ручной проверкой, чтобы отдавать именно `413 payloadTooLarge`.
- Свой `ErrorMiddleware`: любая ошибка → `{"error":{code,message,details?}}` через `APIErrorResponse`. Внутренний тип `ServerError(APIError)` + маппинг `Abort`/`DecodingError` → `malformedRequest`/`notFound`/`internal`.

## Хранилище (Fluent-модели + миграции)
- `devices`: `id UUID`, `name`, `token_hash` (hex SHA-256, unique), `created_at`.
- `counter`: одна строка `value Int64` — монотонный счётчик версий (режим одного пользователя).
- `entities`: `id UUID` (суррогатный ключ Fluent), `kind` (vehicle/serviceRecord), `entity_id UUID`, `vehicle_id UUID?` (для каскада и проверки владельца), `version Int64` (индекс), `modified_at_ms Int64` (точные миллисекунды, без потерь при обмене), `deleted Bool`, `last_change_id UUID`, `data Data?` (DTO в JSON через `APICoding`; `nil` у tombstone). Unique `(kind, entity_id)`, индекс на `version`.
- `receipts`: `sha256` (PK, string), `byte_count`, `bytes Data`, `created_at`. Blob хранится в той же SQLite: ≤ 5 МиБ, один пользователь, бэкап — один файл.

**Последовательность версий.** SQLite и так сериализует запись. Чтобы не ловить `SQLITE_BUSY` и чтобы выделение и коммит версий шли строго по порядку, все записывающие операции push идут через один `actor ChangeWriter`. Каждый элемент — `db.transaction { … }`: внутри читается и увеличивается `counter`, пишутся строки, потом коммит. Только после этого берётся следующий элемент. Это эквивалент требования «блокировка строки счётчика до коммита».

## Эндпоинты (`Controllers/`)
1. `POST /v1/devices` (без auth) → проверка секрета (`401 invalidSetupSecret`), пустое имя → `400 malformedRequest`. Генерация 32 байт → base64url без `=`. В БД кладётся SHA-256 токена. Ответ `201 RegisterDeviceResponse`.
2. `BearerAuthenticator` (`AsyncBearerAuthenticator`): SHA-256 токена → поиск устройства. Нет устройства → `401 unauthorized` (guard middleware с нашим телом ошибки).
3. `GET /v1/changes?after&limit`: `after` — десятичный `Int64 ≥ 0`, иначе `400 malformedRequest` (`details.field = "after"`). `limit` 1…500, по умолчанию 200. Запрос — `version > after ORDER BY version LIMIT limit+1`, лишняя строка задаёт `hasMore`. `cursor` = версия последней отданной строки; при пустом ответе — `after` (или `"0"`). Каждая строка → `ServerChange` (upsert с `data` или delete).
4. `POST /v1/changes`: тело — `PushRequest`, больше 100 элементов → `400`. Для каждого элемента вызывается `ChangeWriter.apply(_:)` → `PushResult`. Ответ `200`.
5. `PUT /v1/receipts/:sha256`: путь — 64 hex в нижнем регистре, иначе `400`. `Content-Type` не `image/jpeg` → `415`. Больше 5 МиБ → `413`. SHA-256 тела ≠ путь → `422 hashMismatch`. Если blob уже есть → `200`, иначе вставка и `201`.
6. `GET /v1/receipts/:sha256` → `200 image/jpeg`, `ETag: "<sha>"`, `Cache-Control: public, max-age=31536000, immutable`. На `If-None-Match` → `304`. Нет blob → `404 notFound`.

## Логика push (`ChangeWriter.apply`, по контракту)
Сначала ищется строка `(kind, id)`. Затем:
- **Идемпотентность:** `row.lastChangeID == changeID` → `applied(row.version)` без записи.
- **upsert:**
  - Валидация **ровно правилами GarageCore, не строже и не мягче** (`Validation.swift`): `VehicleDTO → Vehicle`, `ServiceRecordDTO → ServiceRecord`/`Part`/`Money`/`ServiceType(storageString:)`, `kind` → `VehicleKind(rawValue:)`. Неизвестный `serviceType` отклоняется так же, как в домене: по контракту сервер обновляется раньше клиентов. Своих проверок сверх домена нет. `receipt` проверяется только на существование blob (`receiptNotFound`); невалидный sha256 даёт тот же `receiptNotFound`. Ошибка → `rejected/validationFailed` с `ValidationError` в message.
  - tombstone → `conflict/deleted` (current = tombstone).
  - строки нет: создание, в том числе при `baseVersion != nil` (так сказано в контракте).
  - строка жива: `baseVersion == nil` → `conflict/alreadyExists`; `baseVersion != row.version` → `conflict/versionMismatch`; иначе обновление.
  - Только для serviceRecord: живая vehicle `vehicleID` должна существовать, иначе `rejected/vehicleNotFound`. Если указан `receipt`, blob должен существовать, иначе `rejected/receiptNotFound`.
  - Запись: `version = counter+1`, `modifiedAt`, `lastChangeID`, `data`, `vehicle_id`.
- **delete:**
  - Нет строки → создаётся tombstone с новой версией → `applied`. Это даёт идемпотентность, и запись с этим id больше не воскреснет.
  - Живая строка → tombstone с новой версией, `baseVersion` игнорируется.
  - Уже tombstone (другой changeID) → `applied(row.version)` без новой версии.
  - Удаление vehicle: в той же транзакции каждая живая запись с `vehicle_id` получает tombstone со своей новой версией. У неё `modifiedAt` = modifiedAt удаления, `lastChangeID` = тот же changeID.
- Ошибка БД в элементе → `rejected/internal` для этого элемента, остальные элементы обрабатываются дальше.

## Тесты (`Server/Tests/AppTests`, Swift Testing + `VaporTesting`)
Хелпер `withTestApp { app, client in … }`: in-memory SQLite, тестовый секрет, автомиграция, регистрация устройства и получение токена. Запросы и ответы — через DTO GarageAPI, без копий golden JSON. Сценарии из `docs/api.md`:
- **Auth:** неверный секрет → 401 `invalidSetupSecret`; без токена или с чужим → 401 `unauthorized`; токен — 43 символа base64url, в БД хранится только хеш.
- **Pull:** пустая выгрузка; полная выгрузка, включая tombstones; курсор и `hasMore` (5 изменений, limit 2 → 3 страницы); `after=abc` и `limit=0/501` → 400 `malformedRequest` с `details.field`.
- **Push:** создание → applied/version; **конфликт** `versionMismatch` с `current` (правка с двух «устройств»); `alreadyExists`; **повтор push** с тем же changeID → тот же `applied(version)`; пакет из 101 элемента → 400; ошибка одного элемента не блокирует остальные; `validationFailed` (плохой `kind`, `serviceType`, отрицательный пробег); `vehicleNotFound`.
- **Удаление побеждает правку:** upsert по tombstone → `conflict/deleted`; upsert-создание по id с tombstone → `conflict/deleted`; удаление со старым baseVersion → applied; удаление несуществующего id и повторное удаление → applied.
- **Каскад:** удаление vehicle → tombstones её записей в pull с отдельными версиями; запись в удалённую технику → `vehicleNotFound`.
- **Чеки:** PUT 201 → повтор 200; неверный хеш → 422; не jpeg → 415; > 5 МиБ → 413; GET с ETag и 304; запись со ссылкой на отсутствующий blob → `receiptNotFound`, после PUT — applied.
- **Монотонность:** параллельные push (`withTaskGroup`) → версии без дыр и дублей, pull отдаёт всё.

## `Server/CLAUDE.md`
- Команды: `swift build --package-path Server`, `swift test --package-path Server`, запуск: `GARAGE_DB_PATH=… GARAGE_SETUP_SECRET=… swift run --package-path Server GarageServer serve`.
- Env-переменные.
- **Сервер рассчитан на один экземпляр процесса**: последовательность версий держится на in-process `actor ChangeWriter` и SQLite-файле. Второй процесс или реплика на ту же БД нарушит порядок коммитов, поэтому горизонтальное масштабирование запрещено.
- Правила:
  - контракт — `docs/api.md`, сервер его не меняет (вопросы — в отчёт);
  - DTO только из GarageAPI, валидация через GarageCore;
  - сервер должен собираться на Linux: Crypto вместо CryptoKit, без Apple-only фреймворков;
  - golden JSON не копировать;
  - записи идут только через `ChangeWriter`;
  - пакет не подключать к `project.xcproj`;
  - скретч-файлы — только в scratchpad.
- Definition of done для сервера.

## Вопросы по контракту
Вопросы из первой версии плана (golden CCCC, повторное удаление, upsert с `baseVersion` по неизвестному id, каскад против upsert, строгость валидации, `cursor` пустого pull, auth для чеков) решены в `docs/api.md` (`4f5e732`), и решения совпадают с планом. Новые вопросы, которые всплывут при реализации, — в отчёт; контракт не меняю. Одно уже видно: `receipt.byteCount` не сверяется с размером blob, потому что это не правило домена.

Тесты дополняются сценариями из обновлённого контракта: пример CCCC (удаление несуществующего) → `applied`; DDDD (запись с несуществующей техникой) → `vehicleNotFound`; upsert с `baseVersion` по неизвестному id → создание; повторное удаление → версия tombstone; каскадный tombstone → `conflict/deleted`; пустой pull → `cursor == after`; `GET`/`PUT` чеков без токена → 401.

## Проверка
- `swift build --package-path Server` и `swift test --package-path Server` — все тесты зелёные (первый запуск скачает Vapor).
- Ручной smoke: `swift run` с временной БД в scratchpad, затем `curl` на `POST /v1/devices` → `POST /v1/changes` → `GET /v1/changes`.
- Регрессия: `swift test` для GarageCore, GarageSync, GarageAPI (не должны затрагиваться). `git status` — изменения только в `Server/` и `docs/plans/stage-6b-server.md`.
