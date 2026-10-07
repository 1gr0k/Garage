# Этап 6a: контракт API синхронизации

## Контекст
Готовим синхронизацию «один пользователь, несколько устройств, офлайн-работа» с будущим сервером на Vapor. На этом этапе — только контракт: документ `docs/api.md` и Linux-совместимый пакет `Packages/GarageAPI` с DTO и общей настройкой JSON. Сервера и клиента нет; `GarageSync` пока не трогаем (его незакоммиченный каркас остаётся как есть). «Золотые» JSON-примеры живут **только** в `docs/api.md`, тесты читают их оттуда, поэтому документ и код не могут разойтись.

Решения, согласованные с пользователем:
- **Конфликты:** протокол — оптимистичная блокировка (сервер никогда не перезаписывает молча); политика клиента — LWW по записи целиком.
- **Аутентификация:** токен на устройство, выдаётся по общему секрету сервера.

## Первый шаг реализации
Сохранить этот план в `docs/plans/stage-6a-api-contract.md`.

## Модель синхронизации (суть `docs/api.md`)
- **Сущности:** `vehicle` и `serviceRecord`. Запчасти встроены в запись массивом (собственной синхронизации у них нет, запись заменяется целиком). Upsert всегда несёт полное состояние, не патч.
- **Версии:** у пользователя один монотонный счётчик `Int64`. При каждой записи сущность получает `version` = следующее значение. Удаление — tombstone-строка (`deleted`) со своей версией. Отдельного журнала изменений нет: pull = `WHERE version > cursor ORDER BY version`, по одной (последней) строке на сущность.
- **Pull** `GET /v1/changes?after=<cursor>&limit=<1…500, по умолчанию 200>` → `{changes:[ServerChange], cursor, hasMore}`. `cursor` — непрозрачная строка; без `after` — полная выгрузка (включая tombstones).
- **Push** `POST /v1/changes` `{changes:[PushChange]}` (≤ 100) → `200 {results:[PushResult]}`. Элементы обрабатываются по порядку, каждый в своей транзакции; ошибка одного не блокирует остальные. Порядок важен: техника раньше её записей.
  - `PushChange`: `changeID` (UUID, идемпотентность), `baseVersion` (`null` для создания), `modifiedAt` (время правки на устройстве), операция.
  - `PushResult.status`: `applied` (+`version`), `conflict` (+`reason`, +`current: ServerChange`), `rejected` (+`error`).
  - `reason`: `versionMismatch`, `deleted`, `alreadyExists`.
  - **Идемпотентность:** сервер хранит `lastChangeID` в строке сущности; повтор уже применённого изменения → `applied` с той же версией, а не ложный конфликт.
- **Алгоритм клиента (для 6b):** push очереди → pull до `hasMore == false` → сохранить cursor. Свои изменения, вернувшиеся в pull, клиент узнаёт по совпадающей версии.
- **Формат операции:** `{"op":"upsert","entity":"vehicle","data":{…}}` / `{"op":"delete","entity":"serviceRecord","id":"…"}`. `ServerChange` = `version` + `modifiedAt` + те же поля операции.

### Стратегия конфликтов
Сервер определяет конфликт по `baseVersion`, а решает клиент: часы устройств могут расходиться, поэтому сервер по `modifiedAt` ничего не решает, а только хранит и отдаёт его. Политика клиента — LWW по записи: побеждает больший `modifiedAt`, при равенстве — серверная версия. Победивший клиент повторяет push с `baseVersion = current.version`. Почему не слияние по полям: клиенту пришлось бы хранить базовые копии, а для одного пользователя конфликт — редкость (правка одной и той же записи на двух устройствах офлайн).

### Удаления
- Tombstones хранятся бессрочно: данных мало, компактация не нужна. `410 cursorExpired` зарезервирован на случай, если компактацию введут позже: тогда клиент выполняет полную синхронизацию.
- Удаление побеждает правку (`conflict/deleted`): это явное намерение и защита от «зомби» записей. Повторное удаление идемпотентно (`applied`).
- Удаление техники каскадно создаёт на сервере tombstones её записей; клиент отправляет только удаление техники.
- Запись с неизвестной или удалённой техникой → `rejected/vehicleNotFound`, клиент удаляет её локально.

### Фото чека
- Отдельно от JSON, без base64 (+33 % трафика), с адресацией по содержимому: `PUT /v1/receipts/{sha256}` (тело — сырой `image/jpeg`, ≤ 5 МиБ; `201` новое / `200` уже есть; `422 hashMismatch`; `413`; `415`), `GET /v1/receipts/{sha256}` (`ETag` = хеш, можно кешировать навсегда).
- В записи — `receipt: {"sha256":"…","byteCount":N}` или поле отсутствует. Смена или удаление фото — обычная правка записи, поэтому на неё распространяется та же логика конфликтов.
- Порядок: сначала blob, потом запись. Запись со ссылкой на отсутствующий blob → `rejected/receiptNotFound`. Повтор PUT безопасен. Сборка мусора для blob-ов без ссылок вынесена за рамки этапа.

### Аутентификация
`POST /v1/devices` `{setupSecret, deviceName}` → `201 {deviceID, token}`. Токен — 32 случайных байта в base64url; сервер хранит только его SHA-256, секрет задаётся через env. Все остальные запросы идут с `Authorization: Bearer <token>`, токен на клиенте хранится в Keychain. Устройство отзывается удалением строки на сервере, эндпоинта для этого нет. Только HTTPS (TLS на reverse proxy). Почему не JWT или Sign in with Apple: для одного пользователя это лишняя инфраструктура.

### Версионирование
- Префикс `/v1` в URL.
- В рамках v1 допустимы только аддитивные изменения: новые необязательные поля (декодер игнорирует неизвестные ключи), новые коды ошибок (`APIErrorCode.unknown(String)`), новые эндпоинты.
- Ломающие изменения (переименование или смена типа поля, новые обязательные поля, новые значения `op`/`entity`) → `/v2`; сервер какое-то время обслуживает обе версии, снятую отвечает `426 upgradeRequired`.
- **`serviceType` — терпимый читатель (правило в `docs/api.md`):** DTO передаёт `serviceType` строкой. При маппинге в домен потребитель читает неизвестное значение как `.other(<строка>)`, поэтому новые типы работ — аддитивное изменение v1. Маппинг реализуется в 6b. Нюанс для 6b: при повторной отправке такая запись превратится в `"other:<строка>"`, если клиент не сохранит исходную строку.

### Ошибки
Тело ошибки: `{"error":{"code":"…","message":"…","details":{…}?}}`.

| HTTP | code |
|---|---|
| 400 | `malformedRequest` |
| 401 | `unauthorized`, `invalidSetupSecret` |
| 404 | `notFound` |
| 410 | `cursorExpired` (резерв) |
| 413 | `payloadTooLarge` |
| 415 | `unsupportedMediaType` |
| 422 | `hashMismatch` |
| 426 | `upgradeRequired` |
| 500 | `internal` |

Коды отказа элемента push: `validationFailed`, `vehicleNotFound`, `receiptNotFound`. Конфликт элемента — не HTTP-ошибка, а `200` с результатом по каждому элементу.

### JSON-соглашения
- Ключи в camelCase (`vehicleID`), без `keyEncodingStrategy`.
- Даты в ISO 8601 UTC с миллисекундами (`2026-10-07T09:30:00.000Z`); декодер принимает и вариант без дробной части. Используется `Date.ISO8601FormatStyle`, он есть в swift-foundation на Linux.
- Деньги — целые копейки (`laborCostKopecks`), `serviceType` — строка в формате `ServiceType.storageString` (`"other:<текст>"`), `kind` — `car|motorcycle|bicycle`.
- `nil` не пишется (ключ отсутствует); при чтении `null` и отсутствие равнозначны.
- `.sortedKeys` — детерминированный вывод.

## Пакет `Packages/GarageAPI` (по скиллу add-local-package)
- Linux: да. `Package.swift` по образцу GarageCore (iOS 18 / macOS 15), **без зависимостей**: DTO на примитивах, валидация и маппинг DTO ↔ домен — забота потребителей (появится в 6b; тогда же можно добавить в пакет зависимость от GarageCore). Импортируется только Foundation.
- `Sources/GarageAPI/`:
  - `APICoding.swift` — `APICoding.makeEncoder()` / `makeDecoder()` (даты, `.sortedKeys`), `APIPath` (`/v1`, пути, имена query-параметров, `maxPushBatch = 100`, `maxPullLimit = 500`, `defaultPullLimit = 200`, `maxReceiptBytes`).
  - `EntityDTOs.swift` — `VehicleDTO`, `ServiceRecordDTO`, `PartDTO`, `ReceiptRefDTO`: `public` struct, `var`, memberwise `init`, синтезированный Codable.
  - `Changes.swift` — `EntityKind`, `EntityPayload` (`.vehicle`/`.serviceRecord`), `ChangeOperation` (`.upsert(EntityPayload)` / `.delete(EntityKind, id: UUID)`), `ServerChange`, `PullResponse`, `PushChange`, `PushRequest`, `PushResult` + `PushOutcome` (`.applied(version:)`, `.conflict(reason:current:)`, `.rejected(APIError)`), `ConflictReason`, `PushResponse`. Для перечислений с ассоциированными значениями Codable пишется вручную со стабильными строками (как у `ServiceType`, см. память). Неизвестные `op`/`entity`/`status` → `DecodingError`.
  - `Auth.swift` — `RegisterDeviceRequest`, `RegisterDeviceResponse`.
  - `APIError.swift` — `APIErrorResponse`, `APIError {code, message, details: [String: String]?}`, `APIErrorCode` (строковые коды + `.unknown(String)`), вычисляемый `httpStatus`.
  - Все типы `Hashable, Sendable`.
- `Tests/GarageAPITests/` (Swift Testing):
  - `GoldenExamples.swift` — находит `docs/api.md` от `#filePath`, извлекает блоки ` ```json golden=<name> `. Сравнение — через тестовый `JSONValue: Decodable, Equatable`: семантически, без учёта форматирования и порядка ключей.
  - `GoldenTests.swift` — параметризованный `@Test(arguments:)` по таблице `name → (тип, ожидаемое Swift-значение)`. Для каждого примера: decode(golden) == expected и JSONValue(encode(expected)) == JSONValue(golden). Отдельный тест проверяет, что множество golden-блоков в документе совпадает с таблицей, так что пример без теста (или наоборот) роняет тесты.
  - Точечные тесты: дата без миллисекунд декодируется; неизвестный `op` → ошибка; неизвестный код ошибки → `.unknown`; nil-поле не попадает в вывод.
- Golden-примеры в `docs/api.md` (≈12): `vehicle`, `service-record` (запчасти и чек), `register-device-request/response`, `pull-response` (upsert обоих типов + delete), `push-request` (create + update + delete), `push-response` (applied + conflict + rejected), `error-response`.

## Подключение и CLAUDE.md (по скиллу)
- `project.xcproj`: добавить `GarageAPI` в `packages` и `package-product-members` по образцу GarageSync (по `docs/xcproj-notes.md`), затем `xcprojformatter --update`, `xcodebuild -list`, проверить, что diff минимален.
- `CLAUDE.md`: пункт в Architecture (GarageAPI — DTO контракта, Linux, без зависимостей, golden из `docs/api.md`), команда `swift test --package-path Packages/GarageAPI`, Rules (`GarageAPI` в списке Linux-пакетов; «golden-примеры правятся только в `docs/api.md`»), пункт 1 в Definition of done.

## Открытые вопросы (в конце `docs/api.md`)
Сборка мусора для blob-ов, компактация tombstones, многопользовательский режим.

## Проверка
1. `swift test --package-path Packages/GarageAPI` — golden-тесты и точечные тесты проходят. Негативная проверка: временно испортить ключ в golden-блоке `docs/api.md` и убедиться, что тест падает, затем вернуть.
2. Linux-совместимость: Linux-рантайма на машине нет (docker/podman отсутствуют). Проверяется grep-ом: в `Packages/GarageAPI` только `import Foundation`, без Apple-only API (`ISO8601FormatStyle` есть в swift-foundation).
3. Весь Definition of done из CLAUDE.md: тесты GarageCore и GarageSync, `xcodebuild test` для GarageStorage, сборка приложения, `xcprojformatter` и минимальный diff, проверка каталога строк через jq (новых строк нет).
4. Ревью агентом `swift-reviewer`.
