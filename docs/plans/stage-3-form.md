# Этап 3: экран техники и форма записи ТО

## Контекст
Главный экран показывает список техники из SwiftData, но записи ТО в UI недоступны. Добавляем экран техники (записи ТО, новые сверху, и итоговая сумма расходов) и форму добавления записи. Ввод в форме — строки; сохранение идёт через throwing init-ы GarageCore, ошибки валидации показываются у соответствующих полей.

Решения, согласованные с пользователем:
- **Фото чека — только в хранилище.** Домен о фото не знает: в бизнес-логике оно не участвует, а мегабайты в value-типе удорожают `Hashable`/`Codable` и тянут платформенную обработку изображений. В `ServiceRecordEntity` — `@Attribute(.externalStorage) var receiptImage: Data?` (SwiftData сама выносит блоб в файл, удаляет каскадно; опциональное поле — лёгкая миграция). Перед сохранением фото уменьшается до 2048 px по длинной стороне и пересжимается в JPEG через ImageIO; заодно удаляются EXIF/GPS.
- **Пробег техники не меняется при добавлении записи.** `Vehicle.mileageKm` — ручное значение. Актуальный пробег вычисляется: `max(vehicle.mileageKm, максимум mileageKm по записям)`. Ошибочная запись перестаёт влиять на пробег сразу после её удаления. В форме остаётся подсказка, если пробег записи больше текущего актуального.
- `Money(parsing:)` удаляет любые пробельные символы, включая U+00A0 и U+202F.
- Наличие чека в строке записи — SF Symbol `paperclip`.
- Интерфейс пока на английском.
- Вне этапа: редактирование и удаление записей, просмотр фото чека.

## Первый шаг реализации
Сохранить этот план в `docs/plans/stage-3-form.md`.

## GarageCore
- **Новые инварианты** (стиль: throwing init + `private(set)` + `mutating func updateX(_:) throws(ValidationError)`, `init(from:)` идёт через init):
  - `Part`: название не пустое после trim → `.emptyPartName`; `unitPrice >= 0` → `.negativeAmount(Money)`.
  - `ServiceRecord`: `laborCost >= 0` → `.negativeAmount(Money)`; `.other(text)` с пустым после trim текстом → `.emptyServiceTypeDescription`.
- **`Money(parsing:) throws(ValidationError)`**: удаляет все пробельные символы (`Character.isWhitespace`, в т. ч. U+00A0, U+202F); разделитель дроби — `,` или `.`; не больше двух знаков после него; минус, буквы, пустая строка → `.invalidAmount(String)`.
- **Актуальный пробег**: `Vehicle.currentMileageKm(records:) -> Int` = `max(mileageKm, records.map(\.mileageKm).max() ?? 0)`; учитываются только записи этой техники (`vehicleID == id`).
- **`Sequence<ServiceRecord>.totalCost`** — сумма `totalCost`.
- **`ServiceRecordDraft`** — состояние формы: `date: Date`, `mileageText`, `serviceTypeChoice: ServiceTypeChoice` (CaseIterable: варианты `ServiceType` + `.other`), `otherServiceTypeText`, `laborCostText`, `parts: [PartDraft]` (`id`, `name`, `partNumber`, `unitPriceText`, `quantityText = "1"`), `notes`.
  - `makeRecord(vehicleID:) throws(ServiceRecordDraft.Errors) -> ServiceRecord`: собирает **все** ошибки в `[Field: FieldError]`. `Field`: `.mileage`, `.otherServiceType`, `.laborCost`, `.partName(UUID)`, `.partUnitPrice(UUID)`, `.partQuantity(UUID)`. `FieldError`: `.required`, `.notANumber`, `.invalid(ValidationError)`.
  - Пустая стоимость работ = 0; пустой артикул = `nil`; пустой пробег → `.required`.

## GarageStorage
- `ServiceRecordEntity.receiptImage` (`.externalStorage`), маппинг домена его не трогает.
- `ServiceRecordEntity.descriptor(forVehicle:) -> FetchDescriptor` — фильтр по технике, сортировка дата ↓, пробег ↓.
- `ServiceLog.add(_ record:, receiptImage: Data?, to vehicle: VehicleEntity, in context:) throws` — вставка + `save()`; пробег техники не меняется.
- `ReceiptImage.prepare(_ data: Data) throws -> Data` — ImageIO: даунскейл до 2048 px, JPEG, без метаданных.

## Приложение
- `ContentView`: строки — `NavigationLink(value: vehicle.id)`, `.navigationDestination(for: Vehicle.ID.self)`.
- `VehicleDetailView`: техника и записи через `@Query` по id; шапка — актуальный пробег и итоговая сумма; строки — дата, тип, пробег, сумма, `paperclip` при наличии чека; «+» открывает форму в sheet.
- `ServiceRecordFormView`: DatePicker, пробег (+ подсказка «Vehicle mileage will be X km» при превышении), Picker типа (+ поле для «Other»), стоимость работ, секция запчастей (добавить / удалить свайпом), заметки, PhotosPicker с превью и кнопкой удаления. Ошибки — красный текст под полем, сбрасываются при правке поля.
- Форматирование денег и названий типов работ — в приложении.

## Документация
- `docs/lab-journal.md` перевести из RTF в Markdown.

## Проверка
1. `swift test --package-path Packages/GarageCore`: парсинг `Money` (включая U+00A0 / U+202F), новые инварианты, `currentMileageKm` (включая «ошибочная запись больше не учитывается после удаления из массива»), `totalCost`, `ServiceRecordDraft` (все ошибки сразу, привязка ошибок запчасти к её id, пустая стоимость работ = 0, успешная сборка).
2. `xcodebuild test` для GarageStorage: дескриптор фильтрует и сортирует; `ServiceLog.add` сохраняет фото и не меняет пробег техники; `ReceiptImage.prepare` уменьшает 4000×3000 до ≤ 2048 px JPEG.
3. Сборка приложения.
4. Проход в симуляторе через инструмент управления (tap/text/swipe/screenshot по координатам): сохранить с ошибками → проверить сообщения у полей → исправить, прикрепить фото (загружено через `xcrun simctl addmedia`) → сохранить → запись сверху, сумма и актуальный пробег обновились.
