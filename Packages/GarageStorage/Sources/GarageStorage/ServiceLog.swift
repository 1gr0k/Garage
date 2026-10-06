import Foundation
import GarageCore
import SwiftData

public enum ServiceLog {
    /// Inserts the record (with an optional receipt photo) and saves.
    ///
    /// The vehicle's own `mileageKm` is left alone: the current mileage is derived from the records.
    @discardableResult
    public static func add(
        _ record: ServiceRecord,
        receiptImage: Data? = nil,
        to vehicle: VehicleEntity,
        in context: ModelContext
    ) throws -> ServiceRecordEntity {
        let entity = try ServiceRecordEntity(record, vehicle: vehicle)
        entity.receiptImage = receiptImage
        context.insert(entity)
        do {
            try context.save()
        } catch {
            context.delete(entity)
            throw error
        }
        return entity
    }
}
