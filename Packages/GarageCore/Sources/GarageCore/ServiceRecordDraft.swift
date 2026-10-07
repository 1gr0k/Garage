import Foundation

/// The service types offered by the form: every `ServiceType` case, with `.other` carrying no text.
public enum ServiceTypeChoice: Hashable, Sendable, CaseIterable {
    case oilChange, filters, tires, brakes, chain, suspension, inspection, repair, other
}

extension ServiceTypeChoice {
    /// The form option for a service type; `.other(_)` drops its text.
    public init(_ type: ServiceType) {
        switch type {
        case .oilChange: self = .oilChange
        case .filters: self = .filters
        case .tires: self = .tires
        case .brakes: self = .brakes
        case .chain: self = .chain
        case .suspension: self = .suspension
        case .inspection: self = .inspection
        case .repair: self = .repair
        case .other: self = .other
        }
    }
}

/// Editable state of one part row in the service record form. All numbers are raw text.
public struct PartDraft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var partNumber: String
    public var unitPriceText: String
    public var quantityText: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        partNumber: String = "",
        unitPriceText: String = "",
        quantityText: String = "1"
    ) {
        self.id = id
        self.name = name
        self.partNumber = partNumber
        self.unitPriceText = unitPriceText
        self.quantityText = quantityText
    }
}

/// Editable state of the service record form. Fields hold raw user input;
/// `makeRecord(vehicleID:)` validates it all at once.
public struct ServiceRecordDraft: Hashable, Sendable {
    public var date: Date
    public var mileageText: String
    public var serviceTypeChoice: ServiceTypeChoice
    public var otherServiceTypeText: String
    public var laborCostText: String
    public var parts: [PartDraft]
    public var notes: String

    public init(
        date: Date = Date(),
        mileageText: String = "",
        serviceTypeChoice: ServiceTypeChoice = .inspection,
        otherServiceTypeText: String = "",
        laborCostText: String = "",
        parts: [PartDraft] = [],
        notes: String = ""
    ) {
        self.date = date
        self.mileageText = mileageText
        self.serviceTypeChoice = serviceTypeChoice
        self.otherServiceTypeText = otherServiceTypeText
        self.laborCostText = laborCostText
        self.parts = parts
        self.notes = notes
    }

    /// Черновик для правки существующей записи: обратное отображение `makeRecord`.
    ///
    /// - Parameter decimalSeparator: разделитель копеек в `laborCostText` и `unitPriceText`
    ///   (форма передаёт разделитель текущей локали; `Money(parsing:)` принимает и `,`, и `.`).
    public init(record: ServiceRecord, decimalSeparator: Character = ".") {
        var otherText = ""
        if case .other(let text) = record.serviceType { otherText = text }
        self.init(
            date: record.date,
            mileageText: String(record.mileageKm),
            serviceTypeChoice: ServiceTypeChoice(record.serviceType),
            otherServiceTypeText: otherText,
            laborCostText: record.laborCost == .zero
                ? "" : record.laborCost.editingText(decimalSeparator: decimalSeparator),
            parts: record.parts.map {
                PartDraft(
                    id: $0.id,
                    name: $0.name,
                    partNumber: $0.partNumber ?? "",
                    unitPriceText: $0.unitPrice.editingText(decimalSeparator: decimalSeparator),
                    quantityText: String($0.quantity)
                )
            },
            notes: record.notes
        )
    }

    /// A form field that can carry an error.
    public enum Field: Hashable, Sendable {
        case mileage
        case otherServiceType
        case laborCost
        case partName(UUID)
        case partUnitPrice(UUID)
        case partQuantity(UUID)
    }

    public enum FieldError: Error, Hashable, Sendable {
        case required
        case notANumber
        case invalid(ValidationError)
    }

    /// Every problem found in the draft, keyed by field.
    public struct Errors: Error, Equatable, Sendable {
        public var fields: [Field: FieldError]
    }

    /// Проверяет черновик целиком и собирает запись.
    /// - Parameter id: идентификатор записи; при правке передаётся `id` исходной записи,
    ///   для новой записи каждый вызов создаёт новый `UUID`.
    public func makeRecord(id: ServiceRecord.ID = UUID(), vehicleID: Vehicle.ID) throws(Errors) -> ServiceRecord {
        var errors: [Field: FieldError] = [:]

        let mileage = parseMileage(into: &errors)
        let serviceType = makeServiceType(into: &errors)
        let laborCost: Money
        switch parseMoney(laborCostText, allowEmpty: true) {
        case .success(let value): laborCost = value
        case .failure(let error):
            errors[.laborCost] = error
            laborCost = .zero
        }

        var parts: [Part] = []
        for draft in self.parts {
            if let part = makePart(draft, into: &errors) { parts.append(part) }
        }

        guard errors.isEmpty, let mileage, let serviceType else {
            throw Errors(fields: errors)
        }
        do {
            return try ServiceRecord(
                id: id,
                vehicleID: vehicleID,
                date: date,
                mileageKm: mileage,
                serviceType: serviceType,
                laborCost: laborCost,
                notes: notes,
                parts: parts
            )
        } catch {
            // Unreachable while the checks above mirror the model invariants.
            throw Errors(fields: [.mileage: .invalid(error)])
        }
    }

    /// Parses a mileage in kilometers. All whitespace (including U+00A0 and U+202F) is ignored,
    /// so `"87 400"` is 87400.
    public static func parseMileage(_ text: String) -> Result<Int, FieldError> {
        switch parseInteger(text) {
        case .failure(let error): return .failure(error)
        case .success(let value):
            do {
                try ServiceRecord.validate(mileageKm: value)
                return .success(value)
            } catch {
                return .failure(.invalid(error))
            }
        }
    }

    /// Parses a whole number, ignoring all whitespace (including U+00A0 and U+202F).
    private static func parseInteger(_ text: String) -> Result<Int, FieldError> {
        let compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return .failure(.required) }
        guard let value = Int(compact) else { return .failure(.notANumber) }
        return .success(value)
    }

    private func parseMileage(into errors: inout [Field: FieldError]) -> Int? {
        switch Self.parseMileage(mileageText) {
        case .success(let value): return value
        case .failure(let error):
            errors[.mileage] = error
            return nil
        }
    }

    private func makeServiceType(into errors: inout [Field: FieldError]) -> ServiceType? {
        switch serviceTypeChoice {
        case .oilChange: return .oilChange
        case .filters: return .filters
        case .tires: return .tires
        case .brakes: return .brakes
        case .chain: return .chain
        case .suspension: return .suspension
        case .inspection: return .inspection
        case .repair: return .repair
        case .other:
            let text = otherServiceTypeText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                errors[.otherServiceType] = .required
                return nil
            }
            return .other(text)
        }
    }

    private func makePart(_ draft: PartDraft, into errors: inout [Field: FieldError]) -> Part? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { errors[.partName(draft.id)] = .required }

        var unitPrice = Money.zero
        switch parseMoney(draft.unitPriceText, allowEmpty: false) {
        case .success(let value): unitPrice = value
        case .failure(let error): errors[.partUnitPrice(draft.id)] = error
        }

        var quantity = 1
        switch Self.parseInteger(draft.quantityText) {
        case .failure(let error):
            errors[.partQuantity(draft.id)] = error
        case .success(let value):
            quantity = value
            if value <= 0 {
                errors[.partQuantity(draft.id)] = .invalid(.nonPositiveQuantity(value))
            } else if value > Part.maxQuantity {
                errors[.partQuantity(draft.id)] = .invalid(.quantityTooLarge(value))
            }
        }

        let partNumber = draft.partNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? Part(
            id: draft.id,
            name: name,
            partNumber: partNumber.isEmpty ? nil : partNumber,
            unitPrice: unitPrice,
            quantity: quantity
        )
    }

    private func parseMoney(_ text: String, allowEmpty: Bool) -> Result<Money, FieldError> {
        if text.allSatisfy(\.isWhitespace) {
            return allowEmpty ? .success(.zero) : .failure(.required)
        }
        do {
            let value = try Money(parsing: text)
            return value > .maxAmount ? .failure(.invalid(.amountTooLarge(value))) : .success(value)
        } catch {
            return .failure(.notANumber)
        }
    }
}
