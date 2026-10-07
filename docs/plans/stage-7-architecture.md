# Этап 7: архитектура «Clean + MVVM, гибрид»

## Контекст

Сейчас логика размазана по вью и `SyncController`: `ServiceRecordFormView` берёт `modelContext.container` и зовёт `ServiceLog.add`; `ContentView`/`VehicleDetailView` сами делают `toDomain()` с логированием; `SyncController` напрямую собирает `SwiftDataSyncStore` + `SyncEngine`, импортирует GarageSync/SwiftData/UIKit, «Забыть устройство» не останавливает идущий sync (а `SyncEngine.sync()` вообще не отменяем — работа в неструктурированном `Task`); `GarageApp.init` создаёт контейнер, сеет и делает bootstrap на главном потоке с `fatalError`. Тестов на уровне приложения нет.

Цель — разделить слои (use case в GarageCore, репозитории в GarageStorage, `@Observable @MainActor` ViewModel в приложении), оставить `@Query` только для чтения в тонких вью и закрепить правила документом, проверками в `check.sh`, ревьюером и скиллом.

Решения, согласованные с пользователем:
- ViewModel тестируются в новом unit-test таргете **`GarageTests`** в `project.xcproj` (формат выясняем опытным путём и записываем в `docs/xcproj-notes.md`);
- объём — **только перенос** существующих сценариев (список, детали, добавление записи, синхронизация); правка/удаление описываются в `docs/architecture.md` как шаблон, не реализуются;
- use case заводится только там, где есть правило или оркестрация; иначе ViewModel зависит от порта напрямую (`PrepareReceipt`/`LoadSyncStatus` не нужны);
- реализация в трёх сессиях (A — шаги 1–4, B — 5–8, C — 9); в шаге 9 `swift format lint --strict` и исправления — отдельным коммитом.

## Первый шаг реализации

Сохранить этот план в `docs/plans/stage-7-architecture.md`.

## Слои и зависимости (итог)

```
Garage (app): View → ViewModel → use case (протокол из GarageCore)
              Composition root (Garage/App/) — единственное место, где app импортирует GarageSync и создаёт адаптеры
GarageStorage → GarageSync → GarageAPI, GarageCore      (реализации репозиториев)
GarageCore: домен + use cases + протоколы репозиториев (только Foundation)
```

## Packages/GarageCore (Foundation only, `swift test`)

Новая папка `Sources/GarageCore/UseCases/` (+ `Repositories/` для протоколов). Все протоколы `Sendable`, методы `async throws`.

- **Протоколы репозиториев/портов:**
  - `ServiceRecordRepository { func add(_ record: ServiceRecord, receiptImage: Data?) async throws }` (ошибка «нет машины» — новый `GarageCore.RepositoryError.vehicleNotFound(UUID)`);
  - `ReceiptImagePreparing { func prepare(_ data: Data) async throws -> Data }`;
  - `SyncService { func sync() async throws -> SyncSummary; func status() async throws -> SyncStatus; func resetSyncState() async throws }`;
  - `DeviceRegistrar { func register(serverURL: URL, setupSecret: String, deviceName: String) async throws -> String /* token */ }`;
  - `SyncCredentialsStore { token / serverURL read-save-delete }` (sync, не async — Keychain/UserDefaults).
- **Доменные типы синхронизации:** `SyncSummary { receiptFailureCount, stillPendingCount }`, `SyncStatus { lastSyncAt, pendingCount }`, `SyncFailure: Error` (`notRegistered`, `invalidSetupSecret`, `unauthorized`, `upgradeRequired`, `server(status:)`, `malformedResponse`, `network`, `keychain`, `invalidServerURL`, `other`) — чтобы ViewModel строил сообщения без GarageSync.
- **Use cases** (struct с зависимостями через init, именованный метод):
  - `AddServiceRecord(records:)` — `execute(draft:vehicleID:receipt:) throws` → `draft.makeRecord` (ошибки `ServiceRecordDraft.Errors` пробрасываются как есть) → `records.add`;
  - `RegisterDevice(registrar:credentials:)` — валидация URL (переносим `SyncSettings.validate` сюда как `ServerURLPolicy.validate`), регистрация, сохранение токена и адреса; секрет не сохраняется;
  - `SyncNow(service:credentials:)` — нет токена/адреса → `SyncFailure.notRegistered`;
  - `ForgetDevice(service:credentials:)` — удалить токен, `resetSyncState`.
- **Правило:** use case заводится только там, где есть правило или оркестрация. Без них ViewModel зависит от порта напрямую: подготовка чека — `ReceiptImagePreparing`, статус синхронизации — `SyncService.status()` (отдельных `PrepareReceipt`/`LoadSyncStatus` нет).
- **Тесты** (`Tests/GarageCoreTests/UseCases/`, фейки в `Fakes.swift`): валидация черновика не доходит до репозитория; успешное добавление передаёт запись и чек; http не-localhost отвергается; секрет не попадает в `SyncCredentialsStore`; ошибка Keychain → `SyncFailure.keychain`; `SyncNow` без регистрации; `ForgetDevice` удаляет токен и сбрасывает состояние, адрес сервера остаётся.

## Packages/GarageSync

- **Отмена `SyncEngine.sync()`**: обернуть ожидание общего `Task` в `withTaskCancellationHandler { … } onCancel: { inflight.cancel() }`; в `run()` — `try Task.checkCancellation()` между раундами push, перед pull/страницами pull, перед скачиванием чеков. Транзакционность не страдает: каждое `apply`/`markApplied` атомарно в сторе.
  - Тесты: отмена вызывающей задачи во время «зависшего» транспорта → `CancellationError`, следующие запросы не уходят, курсор не сдвинут.
- **`SyncAPIDeviceRegistrar: DeviceRegistrar`** — обёртка над `SyncAPIClient.registerDevice` + маппинг `SyncError`/`URLError` → `SyncFailure` (`SyncError.toFailure()` в одном месте, используется и стором). Тест на маппинг и на тело запроса (переиспользуем `FakeHTTPTransport`).

## Packages/GarageStorage (iOS, `xcodebuild test`)

- **`SwiftDataServiceRecordRepository: ServiceRecordRepository`** — обёртка над существующим `ServiceLog.add` (логика очереди остаётся там), `ServiceLogError.vehicleNotFound` → `RepositoryError.vehicleNotFound`.
- **`ImageIOReceiptPreparer: ReceiptImagePreparing`** — `@concurrent` вызов `ReceiptImage.prepare`.
- **`SwiftDataSyncService: SyncService`** (actor, держит `ModelContainer` и фабрику `SyncAPIClient`/транспорта по токену и адресу из `SyncCredentialsStore`): `SyncSupport.prepare` → `SyncEngine(store:client:receipts:).sync()` → `recordSyncFinished`; `status()` через `SwiftDataSyncStore`; `resetSyncState` → `SyncSupport.resetSyncState`. Ошибки → `SyncFailure`.
- **Чтение для вью — маппинг в одном месте:** `DisplayMapping.swift` с `VehicleEntity.listItem` / `[VehicleEntity].validVehicles()` и `[ServiceRecordEntity].validRecords()` (логирование битых сущностей через OSLog здесь же, вью только вызывает). Плюс `VehicleListItem { vehicle, recordCount }`.
- **`SampleSeeder.seedIfNeeded`**: принимать `ModelContainer` (свой контекст), чтобы вызываться вне главного потока.
- **`AppBootstrap.prepare(inMemory:) async throws -> ModelContainer`** (`@concurrent`): `makeContainer` → `seedIfNeeded` → `SyncSupport.prepare`.
- Тесты: репозиторий добавляет запись и ставит в очередь; `vehicleNotFound`; `SwiftDataSyncService` с `FakeSyncServer` (sync, status, reset, отмена); `validVehicles` пропускает битую сущность; `AppBootstrap` на in-memory идемпотентен.

## Garage/ (app)

Структура (синхронизируемая папка подхватывает подпапки сама):
```
Garage/App/        GarageApp, AppDependencies (composition root), RootView (loading/error/ready),
                   KeychainCredentialsStore (бывш. KeychainTokenStore + SyncSettings → SyncCredentialsStore)
Garage/Features/VehicleList/      VehicleListView (бывш. ContentView)
Garage/Features/VehicleDetail/    VehicleDetailView
Garage/Features/ServiceRecordForm/ ServiceRecordFormView, ServiceRecordFormViewModel
Garage/Features/Sync/             SyncSettingsView, SyncViewModel
Garage/Shared/     Formatting.swift, SyncFailure+Message.swift
```

- **Composition root** `AppDependencies` (`@MainActor final class`): владеет контейнером и адаптерами, отдаёт фабрики `makeServiceRecordFormViewModel(vehicleID:currentMileageKm:)`, `syncViewModel` (один на приложение). Передаётся через `.environment`.
- **`GarageApp`/`RootView`**: `enum LaunchState { loading, ready(AppDependencies), failed(String) }`; `.task { await launch() }` вызывает `AppBootstrap.prepare()` вне главного потока; ошибка → экран с текстом и кнопкой «Повторить». `fatalError` удаляется. `.modelContainer(container)` ставится только в `ready`.
- **Тонкие вью с `@Query`**: `VehicleListView`, `VehicleDetailView` — `@Query` + `validVehicles()/validRecords()`, без логирования/логики/`modelContext`. Вычисления (`currentMileageKm`, `totalCost`) — уже в GarageCore.
- **`ServiceRecordFormViewModel`** (`@Observable @MainActor`): `draft`, `errors`, `receipt`, `isPreparingReceipt`, `saveFailed`; `loadReceipt(_ data: Data?) async` (отмена/устаревание как сейчас — по generation-счётчику), `save() async -> Bool`, `clearError(for:)`, `removePart(id:)`. Зависит от `AddServiceRecord` и напрямую от `ReceiptImagePreparing`. Вью получает `vehicleID` + пробег вместо `VehicleEntity`, `PhotosPickerItem.loadTransferable` остаётся во вью (UI-тип), байты отдаются VM. `@Environment(\.modelContext)` уходит.
- **`SyncController` → `SyncViewModel`** (`@Observable @MainActor`): то же состояние; `register`, `sync`, `refresh` (напрямую `SyncService.status()`), `forgetDevice() async`. Хранит `syncTask: Task<Void, Never>?`; `forgetDevice` делает `syncTask?.cancel()`, `await syncTask?.value`, затем `ForgetDevice`; `CancellationError` не показывается как ошибка; после forget `refresh` от отменённого sync не перетирает состояние (generation-счётчик). Задачи запускает VM (вью вызывает `viewModel.startSync()`), а не неструктурированный `Task` во вью. Добавить подтверждение `confirmationDialog` для «Забыть устройство». Имя устройства (`UIDevice.current.name`) передаётся из composition root замыканием.
- Сообщения об ошибках — `SyncFailure.message` в `Shared/` (бывш. `SyncController.message(for:)`), ключи каталога не меняются; новые строки (экран ошибки запуска, «Повторить», подтверждение) — сразу в `Localizable.xcstrings` с `ru`.

### Тестовый таргет `GarageTests`
- Добавить в `project.xcproj` unit-test таргет (хост — `Garage.app`, папка `GarageTests` синхронизируемая, `TEST_HOST`/`BUNDLE_LOADER`), Swift Testing. Формат выяснить экспериментом, записать в `docs/xcproj-notes.md`; `xcprojformatter --update`, `xcodebuild -list`.
- Тесты VM с фейковыми зависимостями (фейки протоколов GarageCore): форма — ошибки валидации в `errors`, успешный save, сбой → `saveFailed`, устаревшая загрузка чека не перетирает новый; sync — `isSyncing`, ошибки → сообщение, **forget во время sync отменяет его и не оставляет `lastError`/старые счётчики**, повторная регистрация во время регистрации игнорируется.
- `check.sh` секция `ios`: добавить `xcodebuild test -project Garage.xcodeproj -scheme Garage -destination "$dest"` (вместо отдельного build, если тест собирает приложение).

## Закрепление

- **`docs/architecture.md`** (рус.): слои и таблица «кто кого может импортировать»; правило «use case — только при наличии правила или оркестрации, иначе VM зависит от порта напрямую» (примеры: `AddServiceRecord` vs `ReceiptImagePreparing`); граница `@Query`/ViewModel (чтение для показа — `@Query` + маппинг из `DisplayMapping`; любая запись/логика — VM → use case); composition root; где живут фейки; пример фичи «Добавить запись» от `AddServiceRecord` до `ServiceRecordFormView` с тестами каждого слоя; шаблон для будущих правки/удаления (`SyncQueue.enqueueDelete` уже есть); что проверяет секция `architecture`.
- **`scripts/check.sh`**: новая секция `architecture` (первой, быстрая), `--only architecture`, обновить usage/регэксп:
  - вью (`Garage/Features/**/*View.swift` и любые файлы с `: View {`): разрешены `SwiftUI`, `SwiftData` (для `@Query`), `GarageCore`, `GarageStorage` (только сущности для `@Query`/`DisplayMapping`); запрещены `import GarageSync`, `import GarageAPI`, `modelContext`, `.insert(`, `.save()`, `ServiceLog`, `VehicleLog`, `SyncQueue`, `SyncEngine`, `SyncSupport`;
  - ViewModel (`*ViewModel.swift`) не импортируют `SwiftData`, `GarageStorage`, `GarageSync`, `GarageAPI`;
  - `import GarageSync` в приложении — только в `Garage/App/`;
  - `Packages/GarageCore/Sources`: единственный import — `Foundation`;
  - `swift format lint --strict -r Garage GarageTests Packages/*/Sources Packages/*/Tests Server/Sources Server/Tests`.
  - Каждое нарушение печатается как `file:line: rule`.
- **`.claude/agents/swift-reviewer.md`**: пункт фокуса «Границы слоёв» — `@Query`/`modelContext` в вью сверх чтения, логика во вью, VM знает о SwiftData/GarageSync, use case/протокол не в GarageCore, импорт не-Foundation в GarageCore, неструктурированные `Task` во вью, сборка зависимостей вне composition root, use case без правила/оркестрации; ссылка на `docs/architecture.md`.
- **`.claude/skills/new-feature/SKILL.md`**: первый вопрос — нужен ли use case (есть правило/оркестрация?) или VM зависит от порта напрямую; шаблон use case (GarageCore + тест с фейком) → репозиторий (GarageStorage + тест in-memory) → ViewModel (app + тест в GarageTests) → View (тонкая) → фабрика в `AppDependencies` → строки в каталог → `check.sh`; формат как у `add-local-package`.
- **CLAUDE.md**: раздел Architecture — слои, `GarageTests`, ссылка на `docs/architecture.md`; Commands — `check.sh --only architecture`, `xcodebuild test -scheme Garage`; Definition of done уже покрывает через `check.sh`.

## Порядок переноса (проверка после каждого шага)

Реализация в трёх сессиях; каждая заканчивается зелёным `scripts/check.sh`.

**Сессия A — шаги 1–4 (пакеты и тестовый таргет; приложение ещё на старом коде)**

1. Сохранить план. GarageCore: протоколы, `SyncFailure`, use cases, тесты → `swift test` GarageCore.
2. GarageSync: отмена + `SyncAPIDeviceRegistrar` + маппинг ошибок → `swift test` GarageSync.
3. GarageStorage: репозиторий, preparer, `SwiftDataSyncService`, `DisplayMapping`, `AppBootstrap`, seeder → `xcodebuild test` GarageStorage.
4. Таргет `GarageTests` (пустой тест) + заметки в xcproj-notes → `xcodebuild test -scheme Garage`.

**Сессия B — шаги 5–8 (перенос экранов)**

5. Composition root + `RootView` (loading/error) → сборка, ui-checker: запуск, список виден.
6. Список и детали → ui-checker: список, переход в детали, пробег/сумма.
7. Форма записи + VM + тесты → тесты, ui-checker: ошибка валидации, сохранение, запись в списке.
8. Sync: `SyncViewModel` + тесты, удаление `SyncController` → e2e с локальным сервером (CLAUDE.md): регистрация, sync, forget во время sync.

**Сессия C — шаг 9 (закрепление)**

9. a) `swift format lint --strict` по всему коду, исправления (и при необходимости правки `.swift-format`) — **отдельным коммитом**, без других изменений; `check.sh` зелёный.
   b) Затем: секция `architecture` в `check.sh` (включая lint), `docs/architecture.md`, ревьюер, скилл `new-feature`, CLAUDE.md.

## Проверка

1. `scripts/check.sh` целиком (architecture, linux, ios с `GarageTests`, strings).
2. Негативная проверка секции `architecture`: временно добавить `import GarageSync` во вью и `import OSLog` в GarageCore (с откатом) — секция падает с `file:line`.
3. e2e по CLAUDE.md: локальный сервер, свежая установка, регистрация, добавление записи → sync → `curl GET /v1/changes`; запустить долгий sync (сервер остановлен/задержка) и нажать «Забыть устройство» — sync отменён, ошибки нет, устройство не зарегистрировано.
4. Экран ошибки запуска: тест в `GarageTests` для модели запуска с фейковым bootstrap, бросающим ошибку → `failed`, «Повторить» → `ready`.
5. `swift-reviewer` на итоговый diff; `xcprojformatter --update` и минимальный `git diff` `project.xcproj`.
