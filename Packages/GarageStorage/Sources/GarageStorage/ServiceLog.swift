import Foundation
import GarageCore
import SwiftData

public enum ServiceLog {
    /// Inserts the record (with an optional receipt photo) and saves.
    ///
    /// The vehicle's own `mileageKm` is left alone: the current mileage is derived from the records.
    /// If saving fails, the context is rolled back so the record doesn't linger in it.
    @discardableResult
    public static func add(
        _ record: ServiceRecord,
        receiptImage: Data? = nil,
        to vehicle: VehicleEntity,
        in context: ModelContext
    ) throws -> ServiceRecordEntity {
        try add(record, receiptImage: receiptImage, to: vehicle, in: context) { try $0.save() }
    }

    /// `add` with an injectable save step, so tests can simulate a failing save.
    static func add(
        _ record: ServiceRecord,
        receiptImage: Data?,
        to vehicle: VehicleEntity,
        in context: ModelContext,
        save: (ModelContext) throws -> Void
    ) throws -> ServiceRecordEntity {
        let entity = try ServiceRecordEntity(record, vehicle: vehicle)
        entity.setReceiptImage(receiptImage)
        context.insert(entity)
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        return entity
    }
}
