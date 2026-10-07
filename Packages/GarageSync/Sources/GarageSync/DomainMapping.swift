import Foundation
import GarageAPI
import GarageCore

public enum SyncMappingError: Error, Hashable, Sendable {
    case unknownVehicleKind(String)
}

/// What the server knows about a record but the domain model does not. The storage adapter keeps both
/// fields next to the record and hands them back on push, so a local edit never erases them.
public struct RecordSyncExtras: Hashable, Sendable {
    /// Receipt photo reference; the blob itself travels through `ReceiptBlobStore`.
    public var receipt: ReceiptRefDTO?
    /// The original `serviceType` string when the server sent a value this client does not know.
    public var rawServiceType: String?

    public init(receipt: ReceiptRefDTO? = nil, rawServiceType: String? = nil) {
        self.receipt = receipt
        self.rawServiceType = rawServiceType
    }
}

extension Vehicle {
    public init(dto: VehicleDTO) throws {
        guard let kind = VehicleKind(rawValue: dto.kind) else {
            throw SyncMappingError.unknownVehicleKind(dto.kind)
        }
        try self.init(
            id: dto.id, kind: kind, make: dto.make, model: dto.model, year: dto.year, mileageKm: dto.mileageKm)
    }
}

extension VehicleDTO {
    public init(_ vehicle: Vehicle) {
        self.init(
            id: vehicle.id, kind: vehicle.kind.rawValue, make: vehicle.make, model: vehicle.model,
            year: vehicle.year, mileageKm: vehicle.mileageKm)
    }
}

extension Part {
    public init(dto: PartDTO) throws {
        try self.init(
            id: dto.id, name: dto.name, partNumber: dto.partNumber,
            unitPrice: Money(kopecks: dto.unitPriceKopecks), quantity: dto.quantity)
    }
}

extension PartDTO {
    public init(_ part: Part) {
        self.init(
            id: part.id, name: part.name, partNumber: part.partNumber,
            unitPriceKopecks: part.unitPrice.kopecks, quantity: part.quantity)
    }
}

extension ServiceRecord {
    /// Maps a DTO to the domain. A `serviceType` this client does not know is read as `.other(<string>)`
    /// and the original string is kept in the extras (see `docs/api.md`, "Версионирование").
    public static func decoded(from dto: ServiceRecordDTO) throws -> (record: ServiceRecord, extras: RecordSyncExtras) {
        var extras = RecordSyncExtras(receipt: dto.receipt)
        let serviceType: ServiceType
        do {
            serviceType = try ServiceType(storageString: dto.serviceType)
        } catch {
            serviceType = .other(dto.serviceType)
            extras.rawServiceType = dto.serviceType
        }
        let record = try ServiceRecord(
            id: dto.id, vehicleID: dto.vehicleID, date: dto.date, mileageKm: dto.mileageKm,
            serviceType: serviceType, laborCost: Money(kopecks: dto.laborCostKopecks), notes: dto.notes,
            parts: dto.parts.map(Part.init(dto:)))
        return (record, extras)
    }
}

extension ServiceRecordDTO {
    public init(_ record: ServiceRecord, extras: RecordSyncExtras) {
        // The raw string is sent only while the type is still the unknown value it was read as;
        // a user's change of type is detected by comparison, not by clearing the extras on edit.
        let serviceType: String
        if let raw = extras.rawServiceType, record.serviceType == .other(raw) {
            serviceType = raw
        } else {
            serviceType = record.serviceType.storageString
        }
        self.init(
            id: record.id, vehicleID: record.vehicleID, date: record.date, mileageKm: record.mileageKm,
            serviceType: serviceType, laborCostKopecks: record.laborCost.kopecks, notes: record.notes,
            parts: record.parts.map(PartDTO.init(_:)), receipt: extras.receipt)
    }
}
