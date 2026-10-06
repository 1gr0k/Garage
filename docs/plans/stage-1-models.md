# Этап 1: доменные модели журнала обслуживания (GarageCore)

## Контекст
Сейчас в `GarageCore` есть только `Vehicle` (марка, модель, год) с примерами данных. Для журнала обслуживания нужны модели транспорта (тип, пробег), записей о работах и запчастей. На этом этапе делаем только модели и тесты к ним: без хранения и без UI. Ограничения: пробег хранится в километрах (`Int`), деньги в рублях без `Float`/`Double`. Код должен собираться на Linux, поэтому можно использовать только Foundation.

Решения, согласованные с пользователем:
- Деньги хранятся как целое число копеек (`Int`) внутри типа `Money`.
- `ServiceRecord` хранит стоимость работ. Сумма по запчастям и итог вычисляются, поэтому запчасти не учитываются дважды.
- Тип работ задаётся через `enum` с фиксированными вариантами и `.other(String)` для всего остального.
- Инварианты проверяются не через `precondition`, а через throwing init с `ValidationError`. Декодирование проходит через ту же валидацию.
- У `ServiceType` свой `Codable` со стабильным строковым представлением.

## Первый шаг реализации
Скопировать этот план в `docs/plans/stage-1-models.md`, создав папку `docs/plans/`.

## Модели (`Packages/GarageCore/Sources/GarageCore/`)
**`ValidationError.swift`**: `enum ValidationError: Error, Equatable, Sendable`
- `negativeMileage(Int)`: пробег меньше 0 (`Vehicle`, `ServiceRecord`).
- `nonPositiveQuantity(Int)`: количество ≤ 0 (`Part`).
- Валидируемые поля (`Vehicle.mileageKm`, `ServiceRecord.mileageKm`, `Part.quantity`) объявлены как `public private(set) var`. Менять их можно только через `mutating func updateMileage(_:) throws(ValidationError)` / `updateQuantity(_:)`. При ошибке старое значение сохраняется. Так инвариант проверяется на каждом входе, хотя форма редактирования на этапе 3 станет многословнее.
- Init-ы с проверками помечены `throws`. Свой `init(from:)` декодирует поля и вызывает тот же throwing init, поэтому некорректный JSON отклоняется с той же `ValidationError`. `encode(to:)` остаётся синтезированным.

Все типы `public`, `Hashable, Sendable, Codable`. Сущности, у которых есть `id: UUID`, также `Identifiable`. Стиль повторяет `Vehicle.swift`: `public init` со значением `id: UUID = UUID()` по умолчанию.

**`Money.swift`**: `struct Money`
- `kopecks: Int` — единственное хранимое поле.
- `init(kopecks:)` и `init(rubles: Int, kopecks: Int = 0)`.
- `Comparable`, `AdditiveArithmetic` (`.zero`, `+`, `-`), `static func * (Money, Int) -> Money`.
- `Codable` как одно значение: в JSON записывается число копеек (`singleValueContainer`).
- Форматирование для вывода в этот этап не входит.

**`Vehicle.swift`** (изменения)
- Новый `enum VehicleKind: String, CaseIterable, Codable, Sendable` с вариантами `car`, `motorcycle`, `bicycle`.
- В `Vehicle` добавить `kind: VehicleKind` и `mileageKm: Int` (текущий пробег). Новый init: `init(id:kind:make:model:year:mileageKm:)`.
- `throws`: при `mileageKm < 0` выбрасывается `ValidationError.negativeMileage`.
- `samples` создаются через `try!`: это заведомо корректные константы.
- Обновить `samples`: проставить тип и пробег, а трактор John Deere заменить велосипедом (например, Specialized Rockhopper, 2022), потому что для трактора нет подходящего типа.

**`ServiceType.swift`**: `enum ServiceType`
- Варианты: `oilChange`, `filters`, `tires`, `brakes`, `chain`, `suspension`, `inspection` (ТО), `repair`, `other(String)`.
- Свой `Codable`: значение кодируется одной JSON-строкой. Простые случаи записываются своим именем (`"oilChange"`, `"inspection"` и т.д.), `.other(text)` записывается как `"other:<text>"`. При декодировании префикс `other:` проверяется первым, а неизвестная строка вызывает `DecodingError.dataCorrupted`.

**`Part.swift`**: `struct Part`
- Поля: `id`, `name: String`, `partNumber: String?` (артикул), `unitPrice: Money`, `quantity: Int`.
- Вычисляемое `totalPrice: Money` = `unitPrice * quantity`.
- `throws`: при `quantity <= 0` выбрасывается `ValidationError.nonPositiveQuantity`.

**`ServiceRecord.swift`**: `struct ServiceRecord`
- Поля: `id`, `vehicleID: Vehicle.ID`, `date: Date`, `mileageKm: Int`, `serviceType: ServiceType`, `laborCost: Money`, `notes: String = ""`, `parts: [Part] = []`.
- Вычисляемые `partsCost` (сумма `totalPrice`) и `totalCost` (`laborCost + partsCost`).
- `throws`: при `mileageKm < 0` выбрасывается `ValidationError.negativeMileage`.
- Связь с транспортом идёт через `vehicleID`, а не через вложенность. Так проще хранить данные на следующих этапах.

## Тесты (`Packages/GarageCore/Tests/GarageCoreTests/`, Swift Testing)
- **`MoneyTests.swift`**: `init(rubles:kopecks:)`, сложение и вычитание, умножение на количество, сравнение, `.zero`, Codable записывает в JSON целое число копеек и восстанавливает значение обратно.
- **`VehicleTests.swift`**: обновить существующий тест под новый init. Добавить проверки: новые поля сохраняются, у каждого `samples` свой тип и неотрицательный пробег, Codable восстанавливает модель обратно.
- **`PartTests.swift`**: `totalPrice` с учётом количества, `partNumber` может быть `nil`.
- **`ServiceRecordTests.swift`**: `partsCost` и `totalCost` для нескольких запчастей и для пустого списка, `.other("…")` и Codable восстанавливают запись с запчастями обратно.
- Валидацию проверить через `#expect(throws: ValidationError.…)`: для init-ов и для декодирования некорректного JSON. Exit tests не нужны.
- **`ServiceTypeTests.swift`**: тест, фиксирующий точный JSON всех вариантов, round-trip, ошибка на неизвестной строке.

## Приложение
`ContentView` берёт данные только из `Vehicle.samples`, `displayName` и `year`, поэтому правки в нём не нужны. `project.xcproj` тоже не меняется.

## Проверка
1. Запустить `swift test --package-path Packages/GarageCore`: все тесты проходят.
2. Запустить `xcodebuild -project Garage.xcodeproj -scheme Garage -destination 'generic/platform=iOS Simulator' build`: `BUILD SUCCEEDED`.
3. `grep -rE "import (SwiftUI|UIKit|AppKit|Combine)" Packages/GarageCore` ничего не находит.
