# Этап 6b: движок синхронизации (GarageSync)

## Контекст
Контракт синхронизации описан в `docs/api.md` и реализован в DTO пакета `Packages/GarageAPI` (этап 6a). Теперь нужен клиентский движок: push очереди → pull до `hasMore == false` → сохранить cursor, с LWW-разрешением конфликтов. Пакет `Packages/GarageSync` должен остаться Linux-совместимым (только Foundation, плюс `FoundationNetworking` под `#if canImport`). Подключение к SwiftData/GarageStorage и UI — следующий этап; сейчас — протоколы, in-memory хранилище и фейковый транспорт для тестов. `Server/`, GarageStorage и приложение не трогаем (`Server/` в репозитории и нет).

## Первый шаг реализации
Сохранить этот план в `docs/plans/stage-6b-sync.md`.

## Package.swift
- `dependencies`: добавить `.package(path: "../GarageAPI")`; цель `GarageSync` → `["GarageCore", "GarageAPI"]`; тесты → `["GarageSync", "GarageCore", "GarageAPI"]`.
- `project.xcproj` не меняется: `GarageAPI` уже есть в `packages`, приложение линкует только `GarageSync` (проверяется сборкой).

## Sources/GarageSync
- **`DomainMapping.swift`** — DTO ↔ домен GarageCore:
  - `Vehicle` ↔ `VehicleDTO`, `Part` ↔ `PartDTO` (`Money` ↔ копейки), `ServiceRecord` ↔ `ServiceRecordDTO`.
  - DTO → домен проходит через валидирующие `init` GarageCore (бросают `ValidationError`); неизвестный `kind` → `SyncMappingError.unknownVehicleKind`.
  - `serviceType` (терпимый читатель, `docs/api.md` → «Версионирование»): `ServiceType(storageString:)`; при ошибке → `.other(raw)`, а исходная строка сохраняется в `RecordSyncExtras.rawServiceType`. При push: если `rawServiceType != nil` и `record.serviceType == .other(raw)` — отправляется `raw` без изменений; иначе `storageString`. Тип не перезаписывается при правке — «пользователь сменил тип» вычисляется сравнением (по памяти «derived state over side effects»).
  - Чек: в домене его нет, поэтому `RecordSyncExtras.receipt: ReceiptRefDTO?` хранится рядом с записью и отдаётся обратно при push (иначе правка на устройстве стирала бы чек на сервере). Загрузка blob-ов — не в этом этапе.
  - `RecordSyncExtras { receipt: ReceiptRefDTO?, rawServiceType: String? }` — то, что сервер знает о записи, а домен нет; адаптер GarageStorage потом сохранит оба поля.
- **`SyncModels.swift`**:
  - `EntityRef { kind: EntityKind, id: UUID }`.
  - `SyncEntity`: `.vehicle(Vehicle)` / `.serviceRecord(ServiceRecord, RecordSyncExtras)`, `ref`, `payload` (→ `EntityPayload`), `init(payload:) throws`.
  - `PendingChange { changeID, baseVersion: Int64?, modifiedAt, operation: LocalOperation }`, `LocalOperation`: `.upsert(SyncEntity)` / `.delete(EntityRef)`; `pushChange` (→ `PushChange`).
  - `RemoteChange { version: Int64?, operation: LocalOperation }` — то, что store применяет к локальным данным (version `nil` — локальное удаление после `rejected/vehicleNotFound`).
- **`SyncStore.swift`** — протокол `SyncStore: Sendable`, все методы `async throws` (будущий адаптер к SwiftData сможет жить на MainActor):
  - `pendingChanges() -> [PendingChange]` — очередь в порядке правок (техника раньше её записей обеспечивается порядком правок; одна запись в очереди на сущность — склейку делает реализация).
  - `pendingChange(for: EntityRef) -> PendingChange?`, `version(of: EntityRef) -> Int64?`.
  - `markApplied(changeID:version:)` — убрать из очереди, запомнить версию.
  - `rebase(changeID:onto:)` — LWW выиграла локальная правка: оставить в очереди с новым `baseVersion`.
  - `apply(_ change: RemoteChange, for: EntityRef)` — записать/удалить сущность, запомнить версию (у удалённой сущности версия tombstone остаётся, чтобы старый upsert из pull её не воскресил), выкинуть локальную правку этой сущности из очереди.
  - `discard(changeID:)` — убрать из очереди без изменения данных.
  - `cursor() -> String?`, `setCursor(_:)`.
  - Локальные правки (enqueue) в протокол не входят: движку они не нужны, у in-memory реализации свои методы, у адаптера GarageStorage будут свои.
- **`HTTPTransport.swift`**:
  - `HTTPRequest { method, path, query: [URLQueryItem], headers, body: Data? }`, `HTTPResponse { status: Int, body: Data }` — свои структуры, чтобы фейк и Linux не зависели от `URLRequest`.
  - протокол `HTTPTransport: Sendable { func send(_: HTTPRequest) async throws -> HTTPResponse }`.
  - `URLSessionHTTPTransport(baseURL:, session: URLSession = .shared)` — собирает `URLRequest`, `session.data(for:)`; `import FoundationNetworking` под `#if canImport(FoundationNetworking)`.
- **`SyncAPIClient.swift`** — поверх `HTTPTransport`: `pull(after:limit:)` (`GET APIPath.changes`, `after` только если cursor есть), `push(_: PushRequest)` (`POST`, `Content-Type: application/json`); `Authorization: Bearer <token>`; кодирование через `APICoding`; не-2xx → `SyncError.api(status:, APIError)` (тело `APIErrorResponse`, если декодируется, иначе `SyncError.http(status:)`); число результатов push ≠ числу элементов → `SyncError.malformedResponse`.
- **`SyncEngine.swift`** — `public actor SyncEngine(store:, client:, pullLimit: = APIPath.defaultPullLimit)`, `func sync() async throws -> SyncReport`:
  1. **Push**: пачки по `APIPath.maxPushBatch` из `pendingChanges()`. По результату:
     - `applied(v)` → `markApplied`.
     - `conflict(reason, current)`:
       - `current` совпадает с собственным содержимым (upsert: тот же DTO; delete: current — tombstone) → считаем применённым: `markApplied(version: current.version)` (идемпотентность после потерянного ответа, в т.ч. `alreadyExists` с тем же `data`).
       - `reason == .deleted` или `current` — tombstone → удаление побеждает: `apply(current)` (локальное удаление, очередь чистится).
       - иначе (включая `versionMismatch`, `alreadyExists`, `.unknown`) — LWW по `modifiedAt`: локальная строго новее → `rebase(onto: current.version)`, иначе `apply(current)`. Собственное удаление всегда `rebase` (удаление побеждает).
     - `rejected(vehicleNotFound)` для записи → `apply(локальное удаление)`; прочие `rejected` (`validationFailed`, `receiptNotFound`, неизвестные) → `discard` + в отчёт (локальные данные остаются, чтобы не зациклиться на повторах).
     - Пока после раунда есть перебазированные правки — следующий раунд push; не больше 3 раундов, чтобы не войти в пинг-понг.
     - Ошибка транспорта прерывает sync, очередь не тронута → повтор отправит те же `changeID`.
  2. **Pull**: начиная с `cursor()`, страницы до `hasMore == false`; cursor сохраняется после каждой страницы (обрыв посередине продолжает с последней страницы). На каждое изменение:
     - `version(of:) >= change.version` → своё/устаревшее, пропуск;
     - есть локальная правка этой сущности: удаление с сервера побеждает; upsert — LWW (локальная новее → `rebase(onto: change.version)`, иначе `apply`);
     - иначе `apply`. Ошибка маппинга (невалидные данные, неизвестный `kind`) → изменение пропускается и попадает в отчёт, sync не блокируется.
  3. `410 cursorExpired` при pull → cursor сбрасывается в `nil`, полная выгрузка.
  - `SyncReport { pushed, conflictsResolved, rejected: [(EntityRef, APIError)], pulled, skipped: [(EntityRef, Error)] }` — минимально, для тестов и будущего UI.
- Удаляется заглушка `SyncEngine: struct` и тест `syncEngineCanBeCreated`.

## Tests/GarageSyncTests (Swift Testing)
- `GoldenExamples.swift` — копия загрузчика из `GarageAPITests` (находит `docs/api.md` от `#filePath`, глубина та же) и `JSONValue` для семантического сравнения. Копируется код загрузчика, а не примеры — правило «golden только в `docs/api.md`» соблюдено.
- `InMemorySyncStore` (actor, в тестах): словари сущностей и версий, очередь, cursor; `upsertLocal(_:modifiedAt:changeID:)` / `deleteLocal(_:modifiedAt:changeID:)` с явным `changeID` (детерминизм) и склейкой правок одной сущности (новая правка заменяет старую, `baseVersion` сохраняется).
- `FakeHTTPTransport` (actor): очередь сценариев `.respond(status, Data)` / `.fail(Error)`, запись всех запросов; `.golden("push-response")` читает пример из `docs/api.md`; остальные ответы собираются из DTO через `APICoding` (не литералами JSON).
- `MappingTests` — golden `vehicle` / `service-record` → домен → DTO без потерь (запчасти, `partNumber`, чек); неизвестный `serviceType` → `.other("…")` + `rawServiceType`, обратно — исходная строка; неизвестный `kind` и отрицательный пробег → ошибка.
- `SyncEngineTests`, сценарии:
  1. **push → pull по golden**: store подготовлен так, что очередь совпадает с `push-request`: создание техники 1111 (09:30), правка записи 2222 от 10:00 на версии 42, удаление 3333 на версии 7, создание записи 7777 для техники 9999 (10:02). Тело запроса == golden `push-request` (через `JSONValue`). Ответ — golden `push-response`:
     - 1111 `applied(44)` → снята с очереди, версия 44;
     - 2222 `conflict/versionMismatch`, `current` v45 от 09:45 → локальная (10:00) новее → второй раунд: одно изменение с тем же содержимым и `baseVersion: 45` (ответ `applied(47)` собирается из DTO) → версия 47;
     - 3333 `applied(46)` → удаление снято с очереди, версия tombstone 46;
     - 7777 `rejected/vehicleNotFound` → запись 7777 удалена локально, снята с очереди, отказ в отчёте.
     Затем pull golden `pull-response`: первый запрос без `after`, `limit=200`, есть `Authorization`; версии 41–43 не новее локальных (44, 47, 46) → пропущены, данные не меняются, cursor = `"43"`.
  2. **Новое устройство**: пустой store, golden `pull-response` → техника 1111 (v41) и запись 2222 (v42, `oilChange`) созданы; удаление 3333, которой нет локально, только запоминает версию tombstone 43; cursor `"43"`.
  3. **LWW**: серверная правка новее → локальная заменена `current`, повторного push нет; равные `modifiedAt` → побеждает сервер.
  4. **Обрыв и повтор (idempotency)**: первый push падает ошибкой транспорта → sync бросает, очередь цела; второй sync отправляет байт-в-байт то же тело (те же `changeID`) → `applied`, очередь пуста. Плюс: `conflict`, где `current` совпадает с собственным содержимым, и `alreadyExists` с тем же `data` → считаются применёнными без повторного push.
  5. **conflict/deleted**: локальная правка новее, но ответ — tombstone → запись удалена локально, очередь пуста.
  6. **rejected/vehicleNotFound**: upsert записи → запись удалена локально, очередь пуста, отказ в отчёте.
  7. **Пагинация pull**: две страницы (`hasMore: true`, cursor `"2"` → второй запрос с `after=2`), всё применено, итоговый cursor; обрыв на второй странице оставляет cursor `"2"`, следующий sync продолжает с него.
  8. **Неизвестный `ConflictReason`** (`.unknown("futureReason")`) → разрешается по `current` как LWW.
  9. **Неизвестный `serviceType` сохраняется**: pull записи с `"serviceType": "battery"` → в домене `.other("battery")`, `rawServiceType == "battery"`; локальная правка цены работ → тело push содержит `"battery"`, а не `"other:battery"`. Контрольные случаи: смена типа на `.brakes` → `"brakes"`; `.other("battery")`, выбранный пользователем (без `rawServiceType`) → `"other:battery"`.
  10. **HTTP-ошибки**: 401 с телом ошибки → `SyncError.api(.unauthorized)`; 410 `cursorExpired` → полная выгрузка.

## CLAUDE.md
Только строка про `Packages/GarageSync` в Architecture: движок синхронизации (`SyncEngine`: push → pull, LWW), протоколы `SyncStore` и `HTTPTransport` с реализацией на URLSession, маппинг DTO ↔ домен; зависит от GarageCore и GarageAPI; Linux; `swift test`.

## Проверка
1. `swift test --package-path Packages/GarageSync` — все сценарии проходят.
2. Linux-совместимость (Linux-рантайма нет): grep по `Packages/GarageSync` — только `import Foundation` / `FoundationNetworking` под `#if canImport`, GarageCore, GarageAPI.
3. Полный Definition of done: `swift test` для GarageCore и GarageAPI, `xcodebuild test` для GarageStorage (iPhone 17), сборка приложения, jq-проверка каталога (новых строк нет), `project.xcproj` не изменён.
4. Ревью агентом `swift-reviewer`.
