import Foundation
import GarageAPI
import GarageCore

/// Why a pushed DTO was rejected. `message` ends up in `rejected/validationFailed`.
enum DTOValidationFailure: Error {
    case domain(ValidationError)
    case unknownVehicleKind(String)

    var message: String {
        switch self {
        case .domain(let error): String(describing: error)
        case .unknownVehicleKind(let raw): "unknownVehicleKind(\"\(raw)\")"
        }
    }
}

/// Validates DTO content with exactly the rules of the GarageCore model initializers:
/// the server adds no checks of its own (a receipt reference is only checked for existence elsewhere).
enum DTOValidation {
    static func validate(_ payload: EntityPayload) throws(DTOValidationFailure) {
        switch payload {
        case .vehicle(let dto): _ = try vehicle(dto)
        case .serviceRecord(let dto): _ = try serviceRecord(dto)
        }
    }

    static func vehicle(_ dto: VehicleDTO) throws(DTOValidationFailure) -> Vehicle {
        guard let kind = VehicleKind(rawValue: dto.kind) else { throw .unknownVehicleKind(dto.kind) }
        do {
            return try Vehicle(
                id: dto.id, kind: kind, make: dto.make, model: dto.model, year: dto.year, mileageKm: dto.mileageKm)
        } catch {
            throw .domain(error)
        }
    }

    static func serviceRecord(_ dto: ServiceRecordDTO) throws(DTOValidationFailure) -> ServiceRecord {
        do {
            var parts: [Part] = []
            for part in dto.parts {
                parts.append(
                    try Part(
                        id: part.id, name: part.name, partNumber: part.partNumber,
                        unitPrice: Money(kopecks: part.unitPriceKopecks), quantity: part.quantity))
            }
            return try ServiceRecord(
                id: dto.id,
                vehicleID: dto.vehicleID,
                date: dto.date,
                mileageKm: dto.mileageKm,
                serviceType: try ServiceType(storageString: dto.serviceType),
                laborCost: Money(kopecks: dto.laborCostKopecks),
                notes: dto.notes,
                parts: parts)
        } catch {
            throw .domain(error)
        }
    }
}
