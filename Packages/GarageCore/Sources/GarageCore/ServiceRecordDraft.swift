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

    public func makeRecord(vehicleID: Vehicle.ID) throws(Errors) -> ServiceRecord {
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

    private func parseMileage(into errors: inout [Field: FieldError]) -> Int? {
        let text = mileageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errors[.mileage] = .required
            return nil
        }
        guard let value = Int(text) else {
            errors[.mileage] = .notANumber
            return nil
        }
        guard value >= 0 else {
            errors[.mileage] = .invalid(.negativeMileage(value))
            return nil
        }
        return value
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
        let quantityText = draft.quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
        if quantityText.isEmpty {
            errors[.partQuantity(draft.id)] = .required
        } else if let value = Int(quantityText) {
            quantity = value
            if value <= 0 { errors[.partQuantity(draft.id)] = .invalid(.nonPositiveQuantity(value)) }
        } else {
            errors[.partQuantity(draft.id)] = .notANumber
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
            return .success(try Money(parsing: text))
        } catch {
            return .failure(.notANumber)
        }
    }
}
