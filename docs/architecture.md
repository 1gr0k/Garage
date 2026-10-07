# Архитектура: Clean + MVVM, гибрид

Как устроены слои приложения и куда класть новый код. Правила из раздела «Границы» проверяет
`scripts/check.sh --only architecture`; новую фичу удобно вести по скиллу `new-feature`
(`.claude/skills/new-feature/SKILL.md`). История решения — `docs/plans/stage-7-architecture.md`.

## Слои

```
Garage (app):  View → ViewModel → use case / порт (протоколы из GarageCore)
               Garage/App/ — composition root: единственное место, где создаются адаптеры
GarageStorage → GarageSync → GarageAPI, GarageCore      (реализации портов)
GarageCore:    домен + use case'ы + протоколы портов (только Foundation)
```

| Модуль / папка | Что лежит | Может импортировать |
|---|---|---|
| `GarageCore` | домен (`Vehicle`, `ServiceRecord`, `ServiceRecordDraft`), use case'ы (`UseCases/`), протоколы портов (`Repositories/`), `SyncFailure` | только `Foundation` |
| `GarageAPI` | DTO и JSON-контракт синхронизации | только `Foundation` |
| `GarageSync` | `SyncEngine`, HTTP-клиент, `SyncAPIDeviceRegistrar`, маппинг ошибок в `SyncFailure` | `Foundation`, `GarageCore`, `GarageAPI` |
| `GarageStorage` | SwiftData-сущности, адаптеры портов (`Adapters/`), `DisplayMapping`, `AppBootstrap` | всё выше + `SwiftData`, iOS-фреймворки |
| `Garage/App/` | `GarageApp`, `RootView`, `LaunchModel`, `AppDependencies`, `KeychainCredentialsStore` | всё, включая `GarageSync` |
| `Garage/Features/*/…ViewModel.swift` | `@Observable` ViewModel (MainActor по умолчанию таргета) | `Foundation`, `Observation`, `GarageCore` — **не** `SwiftData`, `GarageStorage`, `GarageSync`, `GarageAPI` |
| `Garage/Features/*/…View.swift` | тонкие SwiftUI-вью | `SwiftUI`, `SwiftData` (для `@Query`), `GarageCore`, `GarageStorage` (сущности для `@Query` и `DisplayMapping`) |
| `Garage/Shared/` | форматирование, `SyncFailure.message` | `Foundation`, `SwiftUI`, `GarageCore` |

## Use case или порт напрямую

Use case заводится **только если есть правило или оркестрация**. Иначе ViewModel зависит от порта
напрямую — обёртка «вызвать один метод репозитория» не нужна.

- `AddServiceRecord` — use case: правило (черновик проверяется `ServiceRecordDraft.makeRecord`, его
  ошибки пробрасываются как есть) + сохранение через `ServiceRecordRepository`.
- `RegisterDevice`, `SyncNow`, `ForgetDevice` — use case'ы: проверка адреса (`ServerURLPolicy`),
  «секрет не сохраняется», «нет регистрации → `SyncFailure.notRegistered`», порядок «сброс, потом
  удаление токена».
- `ReceiptImagePreparing` — порт без use case: ViewModel формы вызывает его сам. Так же статус
  синхронизации — прямо `SyncService.status()`.

Use case — `struct` с зависимостями через `init` и одним именованным методом (`execute`), `Sendable`,
методы `async throws`. Протоколы портов — в `GarageCore/Repositories`, `Sendable`. Ошибки, на которые
ViewModel реагирует по-разному, адаптер переводит в доменные (`RepositoryError.vehicleNotFound`,
`SyncFailure`); прочие сбои хранилища (неудачный `save()` SwiftData) проходят как есть, и ViewModel
показывает их общим сообщением (`saveFailed`). Понадобится различать — добавить случай в
`RepositoryError`, а не ловить ошибки SwiftData в приложении.

## Чтение для показа: `@Query` vs ViewModel

- **Только показ** — `@Query` прямо во вью + маппинг из `GarageStorage/DisplayMapping.swift`
  (`validVehicles()`, `validRecords()`, `VehicleListItem`). Маппинг и логирование битых сущностей —
  там, вью только вызывает. Вычисления (`currentMileageKm`, `totalCost`) — в `GarageCore`.
- **Любая запись или логика** — через ViewModel → use case/порт. Во вью нет `modelContext`,
  `ModelContext(…)`, `.insert(`, `context.save()`, `ServiceLog`/`VehicleLog`/`SyncQueue`/`SyncEngine`/
  `SyncSupport`.
- Асинхронную работу запускает ViewModel (`startSync()`, `save()`); вью вызывает её из действия
  кнопки или `.task`. Долгоживущие задачи, которые надо отменять (sync при «Забыть устройство»),
  хранит ViewModel, а не неструктурированный `Task` во вью.

## Composition root

`Garage/App/AppDependencies.swift` — единственное место, где создаются адаптеры
(`SwiftDataServiceRecordRepository`, `ImageIOReceiptPreparer`, `SwiftDataSyncService`,
`SyncAPIDeviceRegistrar`, `KeychainCredentialsStore`) и собираются use case'ы. Наружу отдаёт фабрики
ViewModel (`makeServiceRecordFormViewModel(vehicleID:currentMileageKm:)`) и общий `syncViewModel`;
в дерево вью попадает через `.environment`. Платформенные значения (`UIDevice.current.name`)
передаются замыканием, чтобы ViewModel о них не знали.

Запуск: `LaunchModel` (`loading` / `ready` / `failed`) вызывает `AppDependencies.bootstrap()` →
`AppBootstrap.prepare()` вне главного потока; ошибка показывается в `RootView` с кнопкой «Повторить».
Длительность шагов `AppBootstrap` пишется в лог `subsystem: Garage, category: Launch`.

## Тесты и фейки

| Слой | Где тесты | Фейки |
|---|---|---|
| use case | `Packages/GarageCore/Tests/GarageCoreTests/UseCases/` (`swift test`) | `…/UseCases/Fakes.swift` — фейки портов |
| адаптер | `Packages/GarageStorage/Tests/GarageStorageTests/AdapterTests.swift` (in-memory контейнер, `xcodebuild test`) | `FakeSyncServer.swift` |
| ViewModel | `GarageTests/` (Swift Testing, хост `Garage.app`) | `GarageTests/Fakes.swift` — фейки портов из GarageCore |
| вью | ui-checker в симуляторе | — |

Фейки реализуют протоколы из `GarageCore`, поэтому ни тесты use case'ов, ни тесты ViewModel не
трогают SwiftData и сеть.

## Пример: «Добавить запись»

1. **Домен / правило** — `ServiceRecordDraft.makeRecord(vehicleID:)` (GarageCore).
2. **Порт** — `ServiceRecordRepository.add(_:receiptImage:)`, ошибка `RepositoryError.vehicleNotFound`
   (`GarageCore/Repositories/Repositories.swift`).
3. **Use case** — `AddServiceRecord.execute(draft:vehicleID:receipt:)`. Тесты: невалидный черновик
   не доходит до репозитория, успешный передаёт запись и чек, ошибка репозитория пробрасывается
   (`UseCaseTests.swift`).
4. **Адаптер** — `SwiftDataServiceRecordRepository` поверх `ServiceLog.add` (запись и постановка в
   очередь синхронизации в одном сохранении). Тесты: запись добавлена и в очереди; нет машины →
   `vehicleNotFound` (`AdapterTests.swift`).
5. **ViewModel** — `ServiceRecordFormViewModel`: `draft`, `errors`, `receipt`, `save() async -> Bool`,
   `loadReceipt(_:)` с generation-счётчиком. Тесты: ошибки валидации в `errors`, успешное сохранение
   с чеком, сбой → `saveFailed`, устаревшая загрузка чека не перетирает новую
   (`ServiceRecordFormViewModelTests.swift`).
6. **View** — `ServiceRecordFormView`: биндинги к `draft`, `PhotosPickerItem` → байты → VM,
   «Сохранить» → `viewModel.save()`.
7. **Composition root** — `AppDependencies.makeServiceRecordFormViewModel`.
8. **Строки** — сразу в `Garage/Localizable.xcstrings` с `ru`.

## Шаблон: правка и удаление (не реализованы)

- Порт: в `ServiceRecordRepository` добавить `update(_ record:)` и `delete(id:)` (`RepositoryError`
  для «записи нет»).
- Use case: `UpdateServiceRecord` — то же правило, что у `AddServiceRecord` (черновик → запись);
  удаление без правил — ViewModel зовёт `delete` порта напрямую, если не появится правило
  (например, подтверждение для записей с чеком).
- Адаптер: правка через `update(from:)` и `SyncQueue.enqueueUpsert`, удаление — `SyncQueue.enqueueDelete`
  в том же сохранении, что и `context.delete`.
- ViewModel: форма переиспользует `ServiceRecordFormViewModel` с режимом правки (черновик из
  существующей записи); удаление — действие в ViewModel экрана деталей.

## Что проверяет `scripts/check.sh --only architecture`

Каждое нарушение печатается как `file:line: rule`:

- вью (`Garage/Features/**/*View.swift` и любые файлы `Garage/` с `: View {`): нет `import GarageSync`/
  `GarageAPI`, `modelContext`, `.insert(`, `ModelContext(`, `context.save()`, `ServiceLog`, `VehicleLog`,
  `SyncQueue`, `SyncEngine`, `SyncSupport`;
- `*ViewModel.swift`: нет `import SwiftData`/`GarageStorage`/`GarageSync`/`GarageAPI`;
- `import GarageSync` в приложении — только в `Garage/App/`;
- `Packages/GarageCore/Sources`: единственный импорт — `Foundation`;
- `swift format lint --strict` по исходникам, тестам и манифестам (`.swift-format` в корне);
- `scripts/test-hooks.sh` — кейсы хуков из `.claude/hooks`.

Проверки текстовые (grep): они ловят типичные ошибки, а не доказывают корректность. То, что grep не
видит (логика во вью, use case без правила, сборка зависимостей вне composition root), проверяет
`swift-reviewer` (пункт «Layer boundaries»).

## Хук против записи через shell

`.claude/hooks/deny-shell-writes.sh` (PreToolUse на Bash) отклоняет запись в файлы проекта через
`>`, `>>`, `>|`, `&>`, `tee` и heredoc с перенаправлением в файл: файлы правятся только Write/Edit,
чтобы работали хуки форматирования, /rewind и права. Разрешены `2>&1`, `/dev/null` и пути вне
проекта (scratchpad, /tmp). Это защита **от привычки** (перенаправления), а не от намеренного обхода:
`cp`, `mv`, `sed -i`, `python -c` и т.п. хук не ловит.
