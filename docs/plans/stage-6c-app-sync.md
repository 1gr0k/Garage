# Этап 6c: синхронизация в приложении (GarageStorage ↔ GarageSync ↔ сервер)

## Контекст

`SyncEngine` (GarageSync) и сервер (`Server/`) готовы, GarageSync/GarageAPI уже слинкованы с приложением, но ничего их не использует: нет реализации `SyncStore` на SwiftData, локальные правки не попадают в очередь, нет регистрации устройства, загрузки/скачивания чеков и UI. Цель — полный цикл: правка в приложении → push на сервер → видна в `curl GET /v1/changes`; данные, созданные через curl → pull → видны в приложении (включая чеки).

Решения, согласованные с пользователем:
- чеки скачиваются **сразу после pull** в том же прогоне sync (ошибки не фатальны, повтор на следующем прогоне);
- демо-машины SampleSeeder синхронизируются как обычные данные (bootstrap-очередь);
- формы «Добавить технику» нет — только API `VehicleLog.add` с постановкой в очередь;
- `Vehicle.samples` получают фиксированные UUID (константы), чтобы демо-машины на разных устройствах были одними и теми же сущностями;
- секрет регистрации не сохраняется нигде (ни `UserDefaults`, ни `@AppStorage`) — только `@State` в памяти до регистрации.

## Первый шаг реализации

Сохранить этот план в `docs/plans/stage-6c-app-sync.md`.

## Packages/GarageCore

- `Vehicle.samples`: каждой машине — фиксированный `id` из публичных констант (`Vehicle.SampleID.…` / `static let` UUID-литералы). Тест: id стабильны между вызовами и уникальны.

## Где живёт адаптер (правила зависимостей)

`SwiftDataSyncStore` — в **GarageStorage** («SwiftData только в GarageStorage»). GarageStorage получает зависимость `../GarageSync` (а через неё GarageAPI). Направление: `GarageStorage → GarageSync → GarageAPI, GarageCore`; GarageSync о хранилище не знает и остаётся Linux-совместимым. Новый пакет не нужен (он бы требовал SwiftData вне GarageStorage), adapter в app-таргете нельзя было бы протестировать. SHA-256 считается в GarageStorage (CryptoKit, iOS), а не в GarageSync (Linux).

## Packages/GarageSync (Foundation only, тесты на Linux)

- **`SyncAPIClient`**: 
  - `static func registerDevice(transport:, setupSecret:, deviceName:) async throws -> RegisterDeviceResponse` (POST `/v1/devices`, без токена);
  - `func uploadReceipt(sha256: String, data: Data) async throws` (PUT `APIPath.receipt(sha256:)`, `Content-Type: image/jpeg`; 200/201 — успех);
  - `func downloadReceipt(sha256: String) async throws -> Data`.
  Ошибки — существующие `SyncError.api/http`.
- **`ReceiptBlobStore`** (новый протокол, `Sendable`, async):
  - `func receiptData(sha256: String) async throws -> Data?` — локальные байты для загрузки (nil → не загружаем, сервер, вероятно, уже имеет blob);
  - `func missingReceipts() async throws -> [ReceiptRefDTO]` — ссылки без локальных байтов;
  - `func storeReceipt(_ data: Data, for ref: ReceiptRefDTO) async throws` — реализация проверяет хэш/размер.
- **`SyncEngine.init(store:client:receipts: (any ReceiptBlobStore)? = nil, pullLimit:)`**:
  - push: перед отправкой батча для каждого upsert записи с `extras.receipt` загрузить blob (хэши, загруженные в этом прогоне, не повторять). Ошибка загрузки одной записи → запись исключается из батча (остаётся в очереди, попадает в `stillPending`), ошибка в `report.receiptFailures`; сетевая ошибка транспорта — пробрасывается как сейчас;
  - после pull: `missingReceipts()` → `downloadReceipt` → `storeReceipt`; ошибки в `report.receiptFailures`, не фатальны.
- **`SyncReport.receiptFailures: [(sha256: String, error: any Error)]`**.
- Тесты (Swift Testing, `FakeHTTPTransport`, in-memory blob store в `TestSupport.swift`): регистрация (тело, отсутствие Authorization, разбор ответа, 401 invalidSetupSecret); PUT до POST /v1/changes в журнале запросов; упавший PUT → запись в `stillPending`, остальные отправлены; повторный хэш не загружается дважды; скачивание после pull и сохранение; ошибка скачивания не ломает sync.

## Packages/GarageStorage (SwiftData, тесты через xcodebuild)

**Package.swift**: добавить `.package(path: "../GarageSync")`, продукт `GarageSync` в зависимости таргета.

**Новые `@Model`** (добавить в `GarageStore.models`):
- `PendingChangeEntity { @Attribute(.unique) changeID: UUID; @Attribute(.unique) refKey: String /* "kind:UUID" */; sequence: Int64; baseVersion: Int64?; modifiedAt: Date; operationJSON: Data }` — операция хранится как JSON `ChangeOperation` через `APICoding` (снимок на момент правки, как в `InMemorySyncStore`); `sequence` даёт порядок правок (машина раньше своих записей).
- `SyncVersionEntity { @Attribute(.unique) refKey: String; kindRaw; entityID: UUID; version: Int64 }` — переживает удаление сущности (tombstone-версия).
- `SyncStateEntity` (singleton): `cursor: String?`, `schemaVersion: Int`, `nextSequence: Int64`, `bootstrapped: Bool`, `lastSyncAt: Date?`.

**Новые поля `ServiceRecordEntity`** (лёгкая миграция: опциональные/с дефолтом): `receiptSHA256: String?`, `receiptByteCount: Int?`, `rawServiceType: String?` (`RecordSyncExtras`), `receiptNeedsDownload: Bool = false`. `hasReceipt` выводится в тех же сеттерах (`receiptSHA256 != nil`): `setReceiptImage(_:)` теперь считает sha256/byteCount; новый `setReceiptRef(_ ref: ReceiptRefDTO?)` для pull (sha совпал — байты сохраняются; иначе image = nil, needsDownload = true).

**Версия схемы**: `GarageStore.schemaVersion = 2` (поднимать при каждом изменении моделей; `SchemaMigrationPlan` вне объёма — изменения аддитивные). При открытии стора: если `SyncStateEntity.schemaVersion != GarageStore.schemaVersion` → `cursor = nil` и удаляются `SyncVersionEntity` для ссылок без pending-правки (иначе движок пропустит изменения с версией ≤ известной), `schemaVersion` обновляется → следующий sync делает полную выгрузку с сервера. Pending-правки сохраняют свой `baseVersion`.

**Очередь локальных правок** — `SyncQueue` (internal, работает в переданном `ModelContext` до `save()`, одна транзакция с данными):
- `enqueueUpsert(_ entity: SyncEntity, in:)`, `enqueueDelete(_ ref: EntityRef, in:)`; `modifiedAt` берётся из `PendingChange(…)` (он округляет до мс — переиспользуем, а не дублируем округление).
- Правило из `InMemorySyncStore.upsertLocal`: правка той же ссылки заменяет операцию/`modifiedAt`/`changeID` и сохраняет `baseVersion` и позицию; иначе новая запись с `baseVersion = SyncVersionEntity.version` и `sequence = nextSequence++`.
- `ServiceLog.add` вызывает `enqueueUpsert(.serviceRecord(record, extras))`; новый `VehicleLog.add(_ vehicle:, in container:)` — то же для машин. Будущие правка/удаление используют те же функции.
- **Bootstrap** (`SyncBootstrap.runIfNeeded`, один раз при `bootstrapped == false`): досчитать sha256 для старых записей с чеком, поставить в очередь все машины, затем все записи без версии и без pending-правки (демо-данные тоже).

**`SwiftDataSyncStore`** — `@ModelActor actor`, реализует `SyncStore` и `ReceiptBlobStore`:
- `pendingChanges` — по `sequence`; `markApplied` — удалить pending, upsert версии; `rebase` — сменить только `baseVersion`; `discard`; `cursor/setCursor`.
- `apply(_:for:)`: upsert машины (создать/`update(from:)`), записи (нужна машина — иначе `StorageMappingError.missingVehicle`, движок кладёт в skipped; `rawServiceType`, `setReceiptRef`), delete (каскад SwiftData; версия-tombstone сохраняется), удалить pending этой ссылки; `version == nil` — версию не трогать. `save()` после каждого вызова.
- `missingReceipts` — `receiptNeedsDownload == true`; `storeReceipt` — сверка SHA-256/размера (CryptoKit), иначе ошибка.
- `recordSyncFinished(at:)` → `lastSyncAt` для UI.

**Тесты** (Swift Testing, in-memory контейнер): постановка в очередь из `ServiceLog.add`/`VehicleLog.add` (мс-округление, `baseVersion`, порядок); замена pending сохраняет `baseVersion`; `markApplied`/`rebase`/`discard`/cursor; `apply` upsert/delete, tombstone не воскрешается; смена `schemaVersion` сбрасывает cursor; bootstrap ставит всё ровно один раз; `setReceiptImage` считает sha; `storeReceipt` отвергает чужой хэш; сквозной тест `SyncEngine + SwiftDataSyncStore + фейковый HTTPTransport` (локальный фейк в тестах, golden JSON не копировать).
- **Два устройства с демо-данными**: stateful-фейк сервера `FakeSyncServer: HTTPTransport` (actor в тестах GarageStorage; минимальная семантика `/v1/changes`: версии, `baseVersion == nil` для существующего id → `conflict/alreadyExists` с `current`, pull по версии). Два in-memory стора сеют `Vehicle.samples`, делают bootstrap и sync по очереди → на сервере ровно 4 машины; второе устройство получает `alreadyExists` с совпадающим содержимым, движок засчитывает как applied (`markApplied` с серверной версией), очередь пуста, `stillPending` пуст, лишних версий/дублей нет.

## Garage/ (app, MainActor)

- **`KeychainTokenStore`** (Security, `kSecClassGenericPassword`, service `Garage.sync`): `read/save/delete`.
- **`SyncSettings`**: адрес сервера в `UserDefaults`; валидация URL — https, http только для `localhost`/`127.0.0.1`.
- **`SyncController`** (`@Observable @MainActor`, в окружении из `GarageApp`): `isRegistered`, `isSyncing`, `lastSyncAt`, `lastError`, `stillPendingCount`, `receiptFailureCount`; `register(serverURL:secret:)` → `SyncAPIClient.registerDevice` (имя — `UIDevice.current.name`) → токен в Keychain; `sync()` → `SwiftDataSyncStore(modelContainer:)` + `URLSessionHTTPTransport` + `SyncEngine` → итоги в состояние; `forgetDevice()`. Ошибки (`SyncError`, `invalidSetupSecret`, `unauthorized`, `URLError`) → локализованные сообщения.
- **`SyncSettingsView`** (Form): секция «Сервер» — адрес, секрет (`SecureField`, только `@State`, очищается после успешной регистрации и не передаётся в `SyncSettings`/`UserDefaults`), «Зарегистрировать устройство» / «Устройство зарегистрировано» + «Забыть устройство»; секция «Синхронизация» — кнопка «Синхронизировать» (с ProgressView), «Последняя синхронизация: …» (`Date.formatted(.relative)`), «%lld изменений ожидают отправки» (plural one/few/many/other), «%lld чеков не загружено» (plural), текст последней ошибки.
- **`ContentView`**: кнопка в тулбаре (шестерёнка/стрелки) → `SyncSettingsView`; убрать мусорный `#Playground`.
- **`GarageApp`**: после `seedIfNeeded` — проверка схемы стора, создание `SyncController`, `.environment(syncController)`.
- **ATS**: на симуляторе используем `http://127.0.0.1:8080`; если ATS блокирует — добавить `Garage/Info.plist` с `NSAllowsLocalNetworking` (через `INFOPLIST_FILE` в `project.xcproj` + `xcprojformatter --update`). Проверяется на e2e.
- **`Localizable.xcstrings`**: все новые строки сразу с `ru`; адрес/ошибки сервера (данные пользователя) — через `Text(verbatim:)`.

## CLAUDE.md

GarageStorage теперь зависит от GarageCore и GarageSync; описать `SwiftDataSyncStore`, `SyncQueue`, `GarageStore.schemaVersion` (поднимать при изменении моделей), запуск локального сервера для e2e.

## Проверка

1. `swift test --package-path Packages/GarageSync`; grep на Linux-совместимость (нет CryptoKit/UIKit/SwiftData в GarageSync).
2. `scripts/check.sh` целиком (linux, ios — GarageStorage тесты + сборка приложения, strings).
3. **E2E** (временная папка в scratchpad):
   - `openssl rand -hex 16 > $TMP/secret`; в фоне `GARAGE_DB_PATH=$TMP/garage.sqlite GARAGE_SETUP_SECRET=$(cat $TMP/secret) swift run --package-path Server GarageServer serve --hostname 127.0.0.1 --port 8080` (ожидание готовности — Monitor/цикл curl, без `timeout`).
   - Перед установкой удалить приложение: `xcrun simctl uninstall 22F52CEA-C2CA-4F1D-A103-CF28E2FE535B <bundle id>` — база создаётся заново с фиксированными UUID демо-машин.
   - Собрать и запустить приложение в симуляторе (UDID из `CLAUDE.local.md`); **ui-checker**: открыть настройки, ввести `http://127.0.0.1:8080` и секрет, зарегистрировать, «Синхронизировать» → статус «Последняя синхронизация: сейчас», 0 ожидающих; добавить запись с чеком → синхронизировать.
   - curl: зарегистрировать второе устройство `POST /v1/devices` → токен; `GET /v1/changes` показывает 4 машины, записи и `receipt.sha256`; `GET /v1/receipts/{sha}` отдаёт JPEG.
   - Второй прогон: через curl `PUT /v1/receipts/{sha}` + `POST /v1/changes` (новая машина и запись с чеком) → ui-checker: «Синхронизировать» → машина в списке, у записи скрепка; проверка русской локализации экрана настроек.
   - Остановить сервер, удалить временную папку.
4. Ревью агентом `swift-reviewer`.
