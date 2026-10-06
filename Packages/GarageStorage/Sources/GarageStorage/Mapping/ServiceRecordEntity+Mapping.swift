import Foundation
import GarageCore

extension ServiceRecordEntity {
    public convenience init(_ record: ServiceRecord, vehicle: VehicleEntity) throws {
        guard record.vehicleID == vehicle.id else {
            throw StorageMappingError.vehicleMismatch(expected: record.vehicleID, actual: vehicle.id)
        }
        self.init(
            id: record.id,
            vehicle: vehicle,
            date: record.date,
            mileageKm: record.mileageKm,
            serviceTypeRaw: record.serviceType.storageString,
            laborCostKopecks: record.laborCost.kopecks,
            notes: record.notes
        )
        parts = record.parts.enumerated().map { PartEntity($1, sortIndex: $0) }
    }

    /// Updates scalar fields and rebuilds `parts`; the vehicle link is left untouched.
    public func update(from record: ServiceRecord) {
        date = record.date
        mileageKm = record.mileageKm
        serviceTypeRaw = record.serviceType.storageString
        laborCostKopecks = record.laborCost.kopecks
        notes = record.notes
        for part in parts {
            modelContext?.delete(part)
        }
        parts = record.parts.enumerated().map { PartEntity($1, sortIndex: $0) }
    }

    public func toDomain() throws -> ServiceRecord {
        guard let vehicle else { throw StorageMappingError.missingVehicle(id) }
        return try ServiceRecord(
            id: id,
            vehicleID: vehicle.id,
            date: date,
            mileageKm: mileageKm,
            serviceType: ServiceType(storageString: serviceTypeRaw),
            laborCost: Money(kopecks: laborCostKopecks),
            notes: notes,
            parts: parts.sorted { $0.sortIndex < $1.sortIndex }.map { try $0.toDomain() }
        )
    }
}
