# Этап 2: хранение данных на SwiftData (GarageStorage)

## Контекст
Сейчас `ContentView` показывает захардкоженный `Vehicle.samples`, хранения нет. Добавляем персистентность на SwiftData так, чтобы `GarageCore` остался платформенно-независимым (Linux, без SwiftData). Для этого заводим отдельный iOS-only пакет `GarageStorage` с `@Model`-классами и маппингом «домен ↔ сущность», подключаем его к приложению и переводим главный экран на чтение из хранилища.

Решения, согласованные с пользователем:
- В SwiftData переносим все три доменных типа: `Vehicle`, `ServiceRecord`, `Part` (UI пока только для техники).
- Примеры заливаются один раз; признак — флаг в `UserDefaults`. Если пользователь удалит всю технику, примеры не вернутся.
- `GarageCore` менять можно, но SwiftData в него не попадает. В `ServiceType` появляется публичное строковое представление для хранения.
- Невалидные строки из БД на главном экране не пропускаются молча: они логируются через `os.Logger`.
- Destination симулятора хранится в `CLAUDE.local.md`, а `CLAUDE.md` ссылается на него.

## Первый шаг реализации
Сохранить этот план в `docs/plans/stage-2-storage.md`.

## Изменения в GarageCore
**`ServiceType.swift`**:
- Приватный `encodedString` превращается в `public var storageString: String`. Формат прежний: `oilChange` / `other:<text>`.
- Новый `public init(storageString: String) throws(ValidationError)`. В него переезжает текущий `switch` из `init(from:)`, неизвестная строка даёт `.unknownServiceType(string)`.
- Codable использует их же: `encode` пишет `storageString`, `init(from:)` вызывает `init(storageString:)`, ловит `ValidationError` и бросает `DecodingError.dataCorruptedError(in:debugDescription:)` с прежним текстом. Тесты `serviceTypeJSONIsStable` и `unknownServiceTypeFailsToDecode` остаются зелёными без правок.

**`ValidationError.swift`**: новый case `unknownServiceType(String)`.

**`ServiceTypeTests.swift`** (дополнить):
- `storageString` для всех вариантов совпадает с элементами JSON из `serviceTypeJSONIsStable`.
- `init(storageString:)` восстанавливает каждый вариант, включая `.other("oilChange")` и `.other("")`.
- `#expect(throws: ValidationError.unknownServiceType("tuning"))`.

## Пакет `Packages/GarageStorage`
**`Package.swift`**: tools 6.0, `platforms: [.iOS(.v18)]`, `dependencies: [.package(path: "../GarageCore")]`, library `GarageStorage`, таргеты `GarageStorage` (зависит от `GarageCore`) и `GarageStorageTests`. Default MainActor isolation не включаем (как в GarageCore).

Следствие iOS-only: `swift test` на macOS-хосте его не соберёт (SwiftData требует платформу выше дефолтной macOS). Тесты гоняем через `xcodebuild test` на симуляторе (см. «Проверка»).

**Сущности (`Sources/GarageStorage/`)** — `public final class` с `@Model`, имена с суффиксом `Entity`, чтобы не путать с доменом. Хранятся только примитивы, без Codable-атрибутов:
- `VehicleEntity.swift`: `@Attribute(.unique) id: UUID`, `kindRaw: String` (`VehicleKind.rawValue`), `make`, `model`, `year: Int`, `mileageKm: Int`; `@Relationship(deleteRule: .cascade, inverse: \ServiceRecordEntity.vehicle) serviceRecords: [ServiceRecordEntity]`.
- `ServiceRecordEntity.swift`: `@Attribute(.unique) id`, `vehicle: VehicleEntity?`, `date: Date`, `mileageKm: Int`, `serviceTypeRaw: String`, `laborCostKopecks: Int`, `notes: String`; `@Relationship(deleteRule: .cascade, inverse: \PartEntity.record) parts: [PartEntity]`.
- `PartEntity.swift`: `@Attribute(.unique) id`, `record: ServiceRecordEntity?`, `name`, `partNumber: String?`, `unitPriceKopecks: Int`, `quantity: Int`, `sortIndex: Int` — to-many в SwiftData не упорядочены, а `ServiceRecord.parts` — массив; порядок восстанавливаем по `sortIndex`.

**Маппинг (`Mapping/` рядом с сущностями, по файлу на тип)**:
- Домен → сущность: `convenience`/designated `init(_ vehicle: Vehicle)`, `init(_ record: ServiceRecord, vehicle: VehicleEntity)` (бросает `StorageMappingError.vehicleMismatch`, если `record.vehicleID != vehicle.id`), `init(_ part: Part, sortIndex: Int)`. Плюс `update(from:)` для правок без delete/insert; у записи `update(from:)` пересобирает `parts`.
- Сущность → домен: `func toDomain() throws -> Vehicle / ServiceRecord / Part`. Идёт через throwing init-ы GarageCore, поэтому битые данные (отрицательный пробег, quantity ≤ 0) дают ту же `ValidationError` — по аналогии с `init(from:)` из этапа 1. `ServiceRecord.vehicleID` берётся из `vehicle?.id`; `nil` → `StorageMappingError.missingVehicle(recordID)`.
- `VehicleKind`: `rawValue` ↔ `VehicleKind(rawValue:)`, неизвестное → `StorageMappingError.unknownVehicleKind(String)`.
- `ServiceType` ↔ `String` через `storageString` и `init(storageString:)`. Неизвестная строка даёт `ValidationError.unknownServiceType`.
- `Money` ↔ `Int` копеек.
- **`StorageMappingError.swift`**: `public enum StorageMappingError: Error, Equatable, Sendable { unknownVehicleKind(String), missingVehicle(UUID), vehicleMismatch(expected: UUID, actual: UUID) }`.

**Контейнер и сидинг**:
- **`GarageModelContainer.swift`**: `public enum GarageStore { public static let models: [any PersistentModel.Type]; public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer }`.
- **`SampleSeeder.swift`**: `public enum SampleSeeder`:
  - `static func insertSamples(into context: ModelContext)` — вставляет `VehicleEntity(_:)` для каждого `Vehicle.samples`.
  - `static func seedIfNeeded(_ context: ModelContext, defaults: UserDefaults = .standard) throws` — если флага `"GarageStorage.didSeedSamples"` нет: `insertSamples`, `context.save()`, затем ставит флаг (флаг только после успешного save).

## Тесты (`Packages/GarageStorage/Tests/GarageStorageTests/`, Swift Testing)
Контекст — in-memory `GarageStore.makeContainer(inMemory: true)`; сущности вставляются в контекст, чтобы работали связи.
- **`VehicleMappingTests.swift`**: round-trip каждого `Vehicle.samples` (`toDomain() == vehicle`); `update(from:)` меняет поля; неизвестный `kindRaw` → `unknownVehicleKind`; `mileageKm = -1` в сущности → `ValidationError.negativeMileage(-1)`.
- **`ServiceRecordMappingTests.swift`**: round-trip записи с несколькими запчастями — совпадает порядок `parts`, `Money`, `.other("Замена свечей")`, `partNumber == nil`; `vehicleMismatch` при чужом `vehicleID`; `missingVehicle` при `vehicle = nil`; битый `serviceTypeRaw` → `ValidationError.unknownServiceType`; `quantity = 0` в `PartEntity` → `ValidationError.nonPositiveQuantity(0)`; сохранённая строка `serviceTypeRaw` равна `"oilChange"` / `"other:…"` (фиксируем формат в БД); каскадное удаление записей и запчастей при удалении `VehicleEntity`.
- **`SampleSeederTests.swift`**: на `UserDefaults(suiteName: UUID().uuidString)` — первый вызов вставляет 4 машины и ставит флаг; второй вызов ничего не добавляет; после удаления всех машин повторный вызов не сидит.

## Подключение к приложению
**`Garage.xcodeproj/project.xcproj`** (по `docs/xcproj-notes.md`): в `packages` добавить `{ "kind": "local", "path": "Packages/GarageStorage" }`, в `package-product-members` таргета `Garage` — `{ "package": "GarageStorage", "product-name": "GarageStorage", "build-phase": { "build-phase": "frameworks" } }`. Запись `GarageCore` остаётся (приложение импортирует его напрямую). Hook сам запустит `xcprojformatter --update`. Если всплывёт что-то новое про формат (например, общий локальный пакет-зависимость) — дописать в `docs/xcproj-notes.md`.

**`Garage/GarageApp.swift`**: создать контейнер `GarageStore.makeContainer()`, вызвать `SampleSeeder.seedIfNeeded(container.mainContext)`, передать в `.modelContainer(container)`. Ошибка создания контейнера — `fatalError` с описанием (восстановиться всё равно нельзя).

**`Garage/ContentView.swift`**: вместо `var vehicles = Vehicle.samples` — `@Query(sort: [SortDescriptor(\VehicleEntity.make), SortDescriptor(\VehicleEntity.model)]) private var entities: [VehicleEntity]`; вью работает с доменом.
  - `@State private var vehicles: [Vehicle] = []` пересчитывается в `.onChange(of: entities, initial: true)`. Так маппинг и лог выполняются при изменении данных, а не при каждом вызове `body`.
  - При ошибке `toDomain()` пишем `Logger(subsystem: Bundle.main.bundleIdentifier ?? "Garage", category: "Storage").error("Skipping invalid vehicle \(entity.id, privacy: .public): \(error)")` и пропускаем строку.
  - Разметка списка не меняется. `#Preview` получает in-memory контейнер с `SampleSeeder.insertSamples`. `#Playground` не трогаем.

**`CLAUDE.local.md`** (новый): destination симулятора для `xcodebuild test`, например `platform=iOS Simulator,name=iPhone 17`. Имя `iPhone 18 Pro` не подходит: таких симуляторов два, и имя неоднозначно. Файл добавить в `.gitignore`.

**`CLAUDE.md`**: в Commands добавить команду тестов GarageStorage с `-destination '<см. CLAUDE.local.md>'` и пояснением, что значение берётся оттуда; в Architecture — пункт про `Packages/GarageStorage` (iOS-only, SwiftData, сущности отдельно от домена, тестируется только через `xcodebuild test`); в Rules — «SwiftData только в GarageStorage»; в Definition of done — тесты GarageStorage.

## Проверка
1. `swift test --package-path Packages/GarageCore`: все тесты проходят, включая `serviceTypeJSONIsStable` без правок.
2. Тесты GarageStorage (из каталога пакета xcodebuild генерирует схему с тест-таргетом; точное имя схемы уточнить через `xcodebuild -list` и записать в CLAUDE.md):
   `cd Packages/GarageStorage && xcodebuild test -scheme GarageStorage -destination '<из CLAUDE.local.md>'`.
3. `xcodebuild -project Garage.xcodeproj -list` — в Resolved packages есть GarageCore и GarageStorage.
4. `xcodebuild -project Garage.xcodeproj -scheme Garage -destination 'generic/platform=iOS Simulator' build` — `BUILD SUCCEEDED`.
5. `grep -rn SwiftData Packages/GarageCore` — пусто; `git diff Garage.xcodeproj/project.xcproj` — только две новые записи.
6. Запустить приложение на симуляторе: при первом запуске видны 4 машины, после перезапуска их по-прежнему 4 (без дублей).
