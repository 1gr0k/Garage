import Foundation

/// Состояние формы машины: сырой ввод, проверка — в `makeVehicle`.
public struct VehicleDraft: Hashable, Sendable {
    /// `nil` — вид не выбран. Допустимо только в правке машины с незнакомым серверным видом
    /// (`unrecognizedKind != nil`): тогда сохранение не трогает сырое значение (решение 9e плана этапа 12).
    public var kind: VehicleKind?
    /// Исходная строка вида, который клиент не знает; форма показывает её в пикере вместо выбранного варианта.
    /// Не редактируется: выбор вида в пикере только обнуляет намерение «оставить» (`kind != nil`).
    public let unrecognizedKind: String?
    public var make: String
    public var model: String
    public var yearText: String
    public var mileageText: String

    public init(
        kind: VehicleKind? = .car,
        unrecognizedKind: String? = nil,
        make: String = "",
        model: String = "",
        yearText: String = "",
        mileageText: String = ""
    ) {
        self.kind = kind
        self.unrecognizedKind = unrecognizedKind
        self.make = make
        self.model = model
        self.yearText = yearText
        self.mileageText = mileageText
    }

    /// Обратное отображение для формы правки: год и пробег — цифры без разделителей.
    /// - Parameter unrecognizedKind: сырой вид машины, если сервер прислал незнакомый; тогда `kind == nil`.
    public init(vehicle: Vehicle, unrecognizedKind: String? = nil) {
        self.init(
            kind: unrecognizedKind == nil ? vehicle.kind : nil,
            unrecognizedKind: unrecognizedKind,
            make: vehicle.make,
            model: vehicle.model,
            yearText: String(vehicle.year),
            mileageText: String(vehicle.mileageKm)
        )
    }

    /// Поле формы, у которого может быть ошибка.
    public enum Field: Hashable, Sendable {
        case kind
        case make
        case model
        case year
        case mileage
    }

    public enum FieldError: Error, Hashable, Sendable {
        case required
        case notANumber
        /// Год вне допустимого диапазона; диапазон нужен для текста ошибки.
        case yearOutOfRange(ClosedRange<Int>)
        case invalid(ValidationError)
    }

    /// Все ошибки черновика по полям.
    public struct Errors: Error, Equatable, Sendable {
        public var fields: [Field: FieldError]
    }

    /// Самый ранний допустимый год выпуска.
    public static let minimumYear = 1900

    /// Допустимые годы выпуска: `1900...currentYear + 1` (модели следующего года продаются заранее).
    public static func allowedYears(currentYear: Int) -> ClosedRange<Int> {
        minimumYear...max(minimumYear, currentYear + 1)
    }

    /// Проверяет черновик целиком и собирает машину. Марка и модель обрезаются по пробелам.
    /// - Parameters:
    ///   - id: идентификатор машины; при правке передаётся `id` исходной машины,
    ///     для новой машины каждый вызов создаёт новый `UUID`.
    ///   - currentYear: текущий год; передаётся параметром, чтобы проверка была детерминированной.
    public func makeVehicle(id: Vehicle.ID = UUID(), currentYear: Int) throws(Errors) -> Vehicle {
        var errors: [Field: FieldError] = [:]

        // Вид не выбран: у машины с незнакомым видом в домене остаётся автомобиль (как в `Vehicle(dto:)`),
        // иначе вид обязателен.
        let resolvedKind: VehicleKind
        if let kind {
            resolvedKind = kind
        } else if unrecognizedKind != nil {
            resolvedKind = .car
        } else {
            resolvedKind = .car
            errors[.kind] = .required
        }

        let make = make.trimmingCharacters(in: .whitespacesAndNewlines)
        if make.isEmpty { errors[.make] = .required }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { errors[.model] = .required }

        var year: Int?
        switch ServiceRecordDraft.parseInteger(yearText) {
        case .failure(let error): errors[.year] = Self.fieldError(error)
        case .success(let value):
            let allowed = Self.allowedYears(currentYear: currentYear)
            if allowed.contains(value) {
                year = value
            } else {
                errors[.year] = .yearOutOfRange(allowed)
            }
        }

        var mileage: Int?
        switch ServiceRecordDraft.parseMileage(mileageText) {
        case .success(let value): mileage = value
        case .failure(let error): errors[.mileage] = Self.fieldError(error)
        }

        guard errors.isEmpty, let year, let mileage else {
            throw Errors(fields: errors)
        }
        do {
            return try Vehicle(id: id, kind: resolvedKind, make: make, model: model, year: year, mileageKm: mileage)
        } catch {
            // Недостижимо, пока проверки выше повторяют инварианты модели.
            throw Errors(fields: [.mileage: .invalid(error)])
        }
    }

    private static func fieldError(_ error: ServiceRecordDraft.FieldError) -> FieldError {
        switch error {
        case .required: .required
        case .notANumber: .notANumber
        case .invalid(let validation): .invalid(validation)
        }
    }
}
