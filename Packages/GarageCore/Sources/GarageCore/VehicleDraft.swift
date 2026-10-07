import Foundation

/// Состояние формы машины: сырой ввод, проверка — в `makeVehicle`.
public struct VehicleDraft: Hashable, Sendable {
    public var kind: VehicleKind
    public var make: String
    public var model: String
    public var yearText: String
    public var mileageText: String

    public init(
        kind: VehicleKind = .car,
        make: String = "",
        model: String = "",
        yearText: String = "",
        mileageText: String = ""
    ) {
        self.kind = kind
        self.make = make
        self.model = model
        self.yearText = yearText
        self.mileageText = mileageText
    }

    /// Обратное отображение для формы правки: год и пробег — цифры без разделителей.
    public init(vehicle: Vehicle) {
        self.init(
            kind: vehicle.kind,
            make: vehicle.make,
            model: vehicle.model,
            yearText: String(vehicle.year),
            mileageText: String(vehicle.mileageKm)
        )
    }

    /// Поле формы, у которого может быть ошибка.
    public enum Field: Hashable, Sendable {
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
            return try Vehicle(id: id, kind: kind, make: make, model: model, year: year, mileageKm: mileage)
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
