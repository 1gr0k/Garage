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
- `UpdateServiceRecord` — use case: то же правило для правки (`id` и `vehicleID` берутся из исходной
  записи) + «ничего не изменилось → порт не вызывается»; сохранение через `ServiceRecordEditing`.
- `ServiceRecordEditing.delete` — порт без use case: правил у удаления нет, подтверждение — это UI.
- `AddVehicle` / `UpdateVehicle` — use case'ы: черновик машины проверяется `VehicleDraft.makeVehicle`
  (непустые марка и модель, год `1900...currentYear + 1`, пробег по правилам `parseMileage`;
  `currentYear` — параметр), в правке сохраняется `id`, «ничего не изменилось → порт не вызывается»;
  сохранение через `VehicleRepository`.
- `VehicleRepository.delete` — порт без use case: каскад на записи делают хранилище и сервер,
  подтверждение — это UI (см. «Удаление техники»).
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
5. **ViewModel** — `ServiceRecordFormViewModel`: `draft`, `errors`, `receiptPreview`, `save() async -> Bool`,
   `loadReceipt(_:)` с generation-счётчиком. Тесты: ошибки валидации в `errors`, успешное сохранение
   с чеком, сбой → `saveFailed`, устаревшая загрузка чека не перетирает новую
   (`ServiceRecordFormViewModelTests.swift`).
6. **View** — `ServiceRecordFormView`: биндинги к `draft`, `PhotosPickerItem` → байты → VM,
   «Сохранить» → `viewModel.save()`.
7. **Composition root** — `AppDependencies.makeServiceRecordFormViewModel`.
8. **Строки** — сразу в `Garage/Localizable.xcstrings` с `ru`.

## Шаблон: правка и удаление

План: `docs/plans/stage-9-edit-delete-records.md`. Реализовано целиком (GarageCore, адаптер, ViewModel, вью).

- Порт: отдельный протокол `ServiceRecordEditing` (`update(_:receipt:)`, `delete(id:)`), а не новые
  методы `ServiceRecordRepository`: существующие адаптеры и фейки не ломаются. Адаптер реализует оба
  протокола. Правка отсутствующей записи — `RepositoryError.recordNotFound`; удаление отсутствующей
  — успех (идемпотентно).
- Чек: `ReceiptChange` (`keep` / `replace(Data)` / `remove`). `keep` не трогает поля чека, в том числе
  у записи с ещё не скачанным чеком. ViewModel вычисляет `ReceiptChange` из своего состояния и
  не хранит флагов вроде «чек удалён».
- Use case: `UpdateServiceRecord` — то же правило, что у `AddServiceRecord` (черновик → запись),
  `id` и `vehicleID` берутся из исходной записи; запись и чек не менялись — порт не вызывается.
  Удаление без правил — ViewModel зовёт `ServiceRecordEditing.delete` напрямую (подтверждение — это UI).
- Черновик: `ServiceRecordDraft(record:decimalSeparator:)` для формы правки (`Money.DecimalSeparator`:
  ViewModel выбирает `.comma`, только если в локали `,`, иначе `.period`), `makeRecord(id:vehicleID:)`.
- Адаптер: `ServiceLog.update` — `update(from:)` и `SyncQueue.enqueueUpsert`; `ServiceLog.delete` —
  `SyncQueue.enqueueDelete` в том же сохранении, что и `context.delete`, **всегда**: pending-правка
  записи схлопывается в delete. «Нет `SyncVersionEntity`» не значит «на сервере записи нет»: push может
  быть в полёте (ответ не найдёт pending по `changeID` и версию не запишет, а pull вернёт запись),
  версии стираются при смене схемы и в «Забыть устройство». Пропустить delete — значит потерять
  удаление; цена лишнего delete — один tombstone (сервер принимает delete несуществующего id). Чек меняется только через `setReceiptImage`. Если тип записи сменили,
  `rawServiceType` сбрасывается. Модель SwiftData не менялась, `schemaVersion` не растёт.
- ViewModel: форма переиспользует `ServiceRecordFormViewModel` с режимом правки (`Mode.edit`);
  состояние чека — одно поле `receiptSelection`, `ReceiptChange` вычисляется из него. Разделитель
  денег выбирает ViewModel по `Locale.current`. Удаление из списка — `VehicleDetailViewModel`
  (`pendingDeletion`, `delete(id:)`), из формы — `ServiceRecordFormViewModel.delete()`.
- Вью: строка записи открывает форму правки (`editingSnapshot()` из `DisplayMapping`); свайп «Удалить» —
  без `role: .destructive`, иначе List уберёт строку до подтверждения.

## Удаление техники

План: `docs/plans/stage-10-vehicles-crud.md` (раздел «Каскадное удаление»). Часть A (GarageCore,
тесты GarageSync и сервера) сделана; хранилище и UI — часть B.

- В очередь ставится **только** `delete(.vehicle, id)`, без delete каждой записи: полноту и атомарность
  каскада даёт сервер (`ChangeWriter.delete` в одной транзакции ставит tombstones всем живым записям
  машины, включая те, которых устройство не видело). Delete машины ставится всегда, даже без
  `SyncVersionEntity` — довод тот же, что у удаления записи.
- В том же сохранении из очереди снимаются **pending-upsert'ы записей машины**: отправленные после
  `delete(V)`, они получили бы `rejected/vehicleNotFound` (новая запись) или `conflict/deleted`, а чек
  попытался бы загрузиться для записи, которой уже нет. Pending-delete записей остаются: delete
  не отклоняется, а каскад пропускает уже удалённые записи.
- То же действует при удалении машины с сервера: контракт `SyncStore.apply` — удаление машины удаляет
  её записи и pending-upsert'ы этих записей (`InMemorySyncStore` в тестах GarageSync повторяет это).
  Код `SyncEngine` не меняется.
- Запись, добавленная к машине, которую уже удалили на другом устройстве, теряется («удаление
  побеждает»): push даёт `rejected/vehicleNotFound`, движок удаляет запись локально, pull приносит
  tombstone машины. Демо-машины с фиксированными UUID по той же причине не воскресают на новом
  устройстве (`conflict/deleted`).

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
