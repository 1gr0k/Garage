# Этап 9: правка и удаление записей ТО

## Контекст

Сейчас запись можно только добавить: `ServiceRecordRepository` содержит один `add`, у `ServiceRecordDraft`
нет инициализатора из записи, а `makeRecord(vehicleID:)` всегда создаёт новый `UUID`. Синхронизация
правку и удаление уже умеет: `SyncQueue.enqueueUpsert` берёт `baseVersion` из `SyncVersionEntity` и
схлопывает повторные правки одной записи, сохраняя её `baseVersion` и место в очереди;
`SyncQueue.enqueueDelete` есть, но пока не вызывается; upsert после delete схлопывается в delete.
Сервер хранит tombstone, LWW описан в `SyncEngine.resolve`. Чек живёт только в `ServiceRecordEntity`:
`hasReceipt`, `receiptSHA256`, `receiptByteCount` и `receiptNeedsDownload` меняет единственный метод
`setReceiptImage(_:)`. В домене чека нет.

Работа делится на две части:

- **A** — только `Packages/GarageCore`, собирается на Linux. Делается в облачной сессии отдельным PR.
- **B** — GarageStorage, ViewModel, вью, строки, тесты и ui-checker. Делается после мержа A.

## Решения

1. **Порт правки — отдельный протокол `ServiceRecordEditing`, а не новые методы в
   `ServiceRecordRepository`.** Если расширить существующий протокол, PR A сломает сборку
   `SwiftDataServiceRecordRepository` и `GarageTests/Fakes.swift`. Их правят только в B, а Linux CI
   этого не заметит: локальная секция `ios` будет красной до мержа B. С отдельным протоколом A ничего
   за пределами GarageCore не ломает. В B адаптер реализует оба протокола. Шаблон в
   `docs/architecture.md` нужно обновить.
2. **Правка — use case `UpdateServiceRecord`.** В нём есть правило: черновик проверяется так же, как в
   `AddServiceRecord`, у записи сохраняются `id` и `vehicleID`. Если ничего не изменилось, порт не
   вызывается, и синхронизация не получает лишнего upsert.
3. **Удаление — без use case.** Правил нет, подтверждение — это UI. ViewModel вызывает
   `ServiceRecordEditing.delete(id:)` напрямую, как разрешает `docs/architecture.md` («Use case или порт
   напрямую»).
4. **Чек при правке передаётся как `ReceiptChange { keep, replace(Data), remove }` (GarageCore).**
   Согласованность `hasReceipt` и `receiptSHA256` обеспечивает адаптер. `keep` не трогает поля чека,
   так что и запись с ещё не скачанным чеком (`receiptNeedsDownload`) остаётся как есть. `replace` и
   `remove` идут только через `setReceiptImage`. ViewModel не хранит флаги вроде «чек удалён»:
   `ReceiptChange` вычисляется из её состояния (derived state).
5. **Удаление отсутствующей записи — успех (идемпотентно).** Цель достигнута: запись могла исчезнуть
   при pull. Правка отсутствующей записи — ошибка `RepositoryError.recordNotFound(UUID)`, форма
   показывает «Запись удалена на другом устройстве».
6. **Модель SwiftData не меняется, поэтому `GarageStore.schemaVersion` не растёт.**

---

## Часть A — GarageCore (облачная сессия, отдельный PR)

Только `Packages/GarageCore/**`. Только `import Foundation`. `GarageStorage`, `Garage/` и `GarageTests/`
не трогаются. Проверка: `swift test --package-path Packages/GarageCore` и
`scripts/check.sh --only architecture`; в CI — job `linux`.

### A1. Черновик из записи — `ServiceRecordDraft.swift`

- `public init(record: ServiceRecord, decimalSeparator: Money.DecimalSeparator = .period)` — обратное отображение для
  формы:
  - `mileageText` — цифры без пробелов;
  - `serviceTypeChoice = ServiceTypeChoice(record.serviceType)`; для `.other(text)` заполняется
    `otherServiceTypeText = text`;
  - `laborCostText`: `.zero` → `""` (пустое поле и так разбирается как ноль), целые рубли → `"1250"`,
    с копейками → `"1250<sep>50"`. Две цифры, разделитель — параметр: VM передаёт
    `.comma`, только если `Locale.current.decimalSeparator == ","`, иначе `.period` (`Money(parsing:)`
    принимает и `,`, и `.`, но не другие знаки вроде `٫`);
  - `parts` → `PartDraft(id: part.id, name:, partNumber: part.partNumber ?? "", unitPriceText:, quantityText:)`.
    `id` части сохраняется, чтобы правка не пересоздавала части в sync;
  - `date` и `notes` — как есть.
  - Форматирование денег — `Money` (например, `func editingText(decimalSeparator:)`). Не
    `NumberFormatter`: он зависит от локали и даёт неразрывные пробелы.
- `makeRecord(id: ServiceRecord.ID = UUID(), vehicleID:)` — параметр `id` со значением по умолчанию;
  существующие вызовы не меняются. Doc-комментарий поправить.

### A2. Порт — `Repositories/Repositories.swift`

```swift
/// Что сделать с фото чека при правке записи.
public enum ReceiptChange: Hashable, Sendable { case keep, replace(Data), remove }

public protocol ServiceRecordEditing: Sendable {
    /// Заменяет поля записи с тем же `id`; `vehicleID` не меняется.
    /// Записи нет → `RepositoryError.recordNotFound`.
    func update(_ record: ServiceRecord, receipt: ReceiptChange) async throws
    /// Удаляет запись вместе с частями и чеком. Записи нет — не ошибка.
    func delete(id: ServiceRecord.ID) async throws
}
```

- `RepositoryError`: добавить `case recordNotFound(UUID)`.

### A3. Use case — `UseCases/UpdateServiceRecord.swift`

```swift
public struct UpdateServiceRecord: Sendable {
    public init(records: any ServiceRecordEditing)
    /// Проверяет черновик, сохраняет `id` и `vehicleID` исходной записи.
    /// Ошибки черновика (`ServiceRecordDraft.Errors`) и репозитория пробрасываются как есть.
    /// Запись и чек не изменились → репозиторий не вызывается.
    public func execute(draft: ServiceRecordDraft, original: ServiceRecord, receipt: ReceiptChange) async throws
}
```

### A4. Тесты

- `ServiceRecordDraftTests.swift`:
  - round-trip: для каждой записи из sample data проверить
    `ServiceRecordDraft(record: r).makeRecord(id: r.id, vehicleID: r.vehicleID) == r`;
  - отдельные случаи: копейки (`,` и `.`), нулевая работа → `""`, `.other("…")`, часть без номера,
    сохранение `PartDraft.id`;
  - `makeRecord(id:)` сохраняет переданный `id`; без `id` каждый вызов даёт новый.
- `MoneyTests.swift`: `editingText` и обратный разбор через `Money(parsing:)`.
- `UseCases/UseCaseTests.swift`, новый `// MARK: UpdateServiceRecord`:
  - невалидный черновик не доходит до репозитория, ошибка — `ServiceRecordDraft.Errors`;
  - у переданной записи `id` и `vehicleID` исходной записи, `ReceiptChange` передан как есть;
  - запись не изменилась и `.keep` → вызова нет; не изменилась и `.remove` / `.replace` → вызов есть;
  - `recordNotFound` пробрасывается.
- `UseCases/Fakes.swift`: `FakeRecordEditor: ServiceRecordEditing` (`NSLock`, `@unchecked Sendable` —
  как `FakeRecordRepository`): `updated: [(ServiceRecord, ReceiptChange)]`, `deleted: [UUID]`,
  `var error`.

### A5. Документация

- `docs/architecture.md`, раздел «Шаблон: правка и удаление» — заменить на то, что появилось в A:
  `ServiceRecordEditing`, `ReceiptChange`, `UpdateServiceRecord`, удаление без use case. Ссылка на этот план.

Готово, когда `swift test` GarageCore зелёный, `check.sh --only architecture` чистый, CI `linux`
зелёный. Код вне `Packages/GarageCore` и `docs/` не меняется.

---

## Часть B — хранилище, приложение, UI (после мержа A)

### B1. GarageStorage

- `ServiceLog.swift` — по образцу `add`: свежий `ModelContext`, `autosaveEnabled = false`, одно
  сохранение, перегрузка с инъекцией `save` для тестов.
  - `update(_ record:, receipt: ReceiptChange, in:)`:
    1. Найти сущность по `id`; если её нет — `ServiceLogError.recordNotFound`.
    2. `entity.update(from: record)`.
    3. Если тип записи больше не равен `.other(rawServiceType)` — сбросить `rawServiceType`. Иначе
       неизвестный серверный тип «воскреснет» после последующей правки.
    4. `.replace(d)` → `setReceiptImage(d)`, `.remove` → `setReceiptImage(nil)`, `.keep` → ничего.
    5. `SyncQueue.enqueueUpsert(.serviceRecord(record, entity.syncExtras))` — после шага 4, чтобы в
       extras попал актуальный `ReceiptRefDTO`.
    6. `save`.
  - `delete(id:in:)`: сущности нет → вернуться без ошибки. Иначе
    `SyncQueue.enqueueDelete(.serviceRecord(id))`, затем `context.delete(entity)` (части удаляются
    каскадом, чек во внешнем хранилище — вместе с сущностью), затем `save`. Всё в одном сохранении.
- `Adapters/SwiftDataServiceRecordRepository.swift`: реализует `ServiceRecordEditing` и переводит
  `ServiceLogError.recordNotFound` в `RepositoryError.recordNotFound`.
- `DisplayMapping.swift`: что нужно форме правки из сущности — `ServiceRecord`, `hasReceipt`,
  `receiptImage: Data?`. Добавить маппинг, например `ServiceRecordEntity.editingSnapshot()`, чтобы вью
  не собирала это сама.
- Тесты (`ServiceLogTests.swift`, `AdapterTests.swift`, in-memory):
  - правка: поля обновлены, `id` тот же, части пересобраны с прежними `id`; в очереди один upsert с
    `baseVersion` из `SyncVersionEntity`;
  - две правки подряд → один pending с исходными `baseVersion` и позицией;
  - чек `keep` / `replace` / `remove`: после каждой операции `hasReceipt == (receiptSHA256 != nil)`, а
    хэш равен `sha256` новых байтов. `keep` при `receiptNeedsDownload == true` ничего не меняет.
    `remove` даёт upsert с `receipt == nil`;
  - `rawServiceType` сохраняется, если тип не трогали, и сбрасывается, если тип поменяли;
  - правка отсутствующей записи → `RepositoryError.recordNotFound`;
  - удаление: сущность и части удалены, в очереди delete с `baseVersion`; удаление ещё не
    отправленной записи схлопывается в один delete; удаление отсутствующей записи — без ошибки и без
    pending;
  - через `FakeSyncServer` и `SyncEngine`: правка → push upsert с `baseVersion`, новый чек загружается
    до push; удаление → push delete; после pull в базе нет записи.

### B2. ViewModel

- `ServiceRecordFormViewModel`:
  - Режим `enum Mode { case add(vehicleID:), edit(original: ServiceRecord, hasStoredReceipt: Bool) }`.
    Зависимости через `init`: `AddServiceRecord`, `UpdateServiceRecord`, `any ServiceRecordEditing`
    (для delete), `ReceiptImagePreparing`.
  - Состояние чека — одно поле `receiptSelection`:
    - `.stored(Data?)` — чек из базы; `nil`, если ещё не скачан;
    - `.picked(Data)` — новый чек;
    - `.none` — чека нет.

    `receiptChange` вычисляется так: `.stored` → `.keep`, `.picked` → `.replace`, `.none` →
    `.remove`, если чек был, иначе `.keep`. `loadReceipt` (generation-счётчик) ставит `.picked`,
    `removeReceipt()` ставит `.none`. Текущее `receipt: Data?` заменяется на вычисляемое
    `receiptPreview`.
  - Черновик при правке — `ServiceRecordDraft(record:decimalSeparator:)`: `.comma`, если `Locale.current.decimalSeparator == ","`, иначе `.period`.
  - `save()`:
    - в режиме `add` — как сейчас;
    - в режиме `edit` — `updateServiceRecord.execute(draft:original:receipt:)`;
    - `recordNotFound` → `recordGone = true` (алерт, потом закрыть форму);
    - другие ошибки → `saveFailed`.
  - `delete() async -> Bool` — только в режиме `edit`. Повторный вызов во время работы
    игнорируется (`isDeleting`), сбой → `deleteFailed`. Кнопки «Сохранить» и «Удалить» блокируют друг
    друга.
  - `currentMileageKm` в режиме правки — пробег без учёта этой записи. Его считает вызывающий, см. B3.
- Новый `Features/VehicleDetail/VehicleDetailViewModel.swift`:
  - `pendingDeletion: ServiceRecord.ID?` — для confirmationDialog;
  - `delete() async` — через `ServiceRecordEditing.delete`;
  - `deleteFailed`.
- `GarageTests/Fakes.swift`: `FakeRecordRepository` также реализует `ServiceRecordEditing`.
  Используется `Gate`, чтобы тесты гонок были детерминированными.
- Тесты:
  - `ServiceRecordFormViewModelTests`:
    - черновик правки заполнен из записи;
    - `save` в режиме `edit` передаёт `.keep` / `.replace` / `.remove` по сценарию;
    - `.stored(nil)` (чек не скачан) и `save` → `.keep`;
    - `recordNotFound` → `recordGone`;
    - `delete` успешный и со сбоем;
    - повторный `delete` при закрытом `Gate` даёт один вызов;
    - `save` во время `delete` не вызывается.
  - Новый `VehicleDetailViewModelTests`: подтверждение → delete, сбой → `deleteFailed`, отмена
    подтверждения → нет вызова.

### B3. Вью

- `VehicleDetailView`:
  - строка записи — кнопка, она открывает `.sheet(item: $editing)` с формой в режиме `edit`; данные
    берутся из `editingSnapshot()`;
  - `currentMileageKm` для правки — `vehicle.currentMileageKm(records: records.filter { $0.id != id })`;
  - `.swipeActions(edge: .trailing, allowsFullSwipe: false)`: кнопка «Удалить» с `.tint(.red)` и
    **без** `role: .destructive`, иначе List убирает строку до подтверждения. Кнопка ставит
    `viewModel.pendingDeletion`;
  - `.confirmationDialog` → `viewModel.delete()`; ошибка удаления — алертом.
- `ServiceRecordFormView`:
  - заголовок «New Record» или «Edit Record» в зависимости от режима;
  - секция «Чек»:
    - если есть превью — изображение и кнопки «Заменить фото» (`PhotosPicker`) и «Удалить фото»;
    - если `.stored(nil)` — текст «Фото чека ещё не загружено» и те же две кнопки;
    - если чека нет — «Прикрепить фото чека».
  - в режиме правки — секция с кнопкой «Удалить запись» (`role: .destructive`) →
    `confirmationDialog` → `delete()` → `dismiss()`;
  - алерты `deleteFailed` и `recordGone`.

### B4. Composition root

- `AppDependencies`: один `SwiftDataServiceRecordRepository` для обоих портов, `UpdateServiceRecord`.
- Фабрики:
  - `makeServiceRecordFormViewModel(vehicleID:currentMileageKm:)` — как сейчас;
  - `makeServiceRecordFormViewModel(editing: ServiceRecord, hasStoredReceipt: Bool, storedReceipt: Data?, currentMileageKm:)`;
  - `makeVehicleDetailViewModel()`.

### B5. Строки (`Garage/Localizable.xcstrings`, сразу `ru`, `state: translated`)

| en | ru |
|---|---|
| Edit Record | Изменить запись |
| Delete | Удалить |
| Delete Record | Удалить запись |
| Delete this record? | Удалить эту запись? |
| This can't be undone. | Это действие нельзя отменить. |
| Couldn't Delete | Не удалось удалить |
| The record could not be deleted. Please try again. | Не удалось удалить запись. Попробуйте ещё раз. |
| Record Deleted | Запись удалена |
| This record was deleted on another device. | Эта запись была удалена на другом устройстве. |
| Replace Photo | Заменить фото |
| The receipt photo hasn't been downloaded yet. | Фото чека ещё не загружено. |

Пользовательские данные в диалогах — например, тип работ в заголовке подтверждения — только через
`Text(verbatim:)` или интерполяцию `String`, не ключом каталога.

### B6. Проверка

- `scripts/check.sh` целиком: architecture, linux, ios, strings.
- ui-checker, на `en` и `ru` (`-AppleLanguages "(ru)"`):
  1. Тап по записи открывает форму «Изменить запись», поля заполнены. Изменить пробег, сохранить —
     строка в списке обновилась.
  2. Запись с чеком: «Заменить фото» → сохранить → скрепка на месте. Открыть снова → «Удалить фото» →
     сохранить → скрепки нет.
  3. Свайп по строке → «Удалить» → диалог → «Отмена»: строка на месте. Повтор с подтверждением:
     строки нет.
  4. Форма правки → «Удалить запись» → подтверждение: форма закрыта, записи нет.
  5. Сквозной сценарий с локальным сервером (CLAUDE.md, «Local server») — по желанию: правка и
     удаление синхронизируются, проверить через pull на чистой установке.
- swift-reviewer на diff.
- `docs/architecture.md`: раздел «Пример» дополнить правкой и удалением (`ServiceLog.update`/`delete`,
  режим формы, `VehicleDetailViewModel`).

## Риски

- Чек заменён, а до push запись удалили или чек заменили ещё раз. Очередь схлопывается до последней
  операции, старый хэш не отправляется — тест в B1.
- Pull удаляет запись, пока открыта форма правки: `recordNotFound` → алерт «Запись удалена». Удаление
  в этом состоянии идемпотентно.
- Правка конфликтует с удалением на сервере: удаление побеждает (`SyncEngine.resolve`), локальная
  правка теряется. Это ожидаемое поведение LWW + tombstone, менять его не нужно.
