import Foundation
import GarageCore
import GarageSync
import SwiftData

public enum ServiceLogError: Error, Hashable, Sendable {
    case vehicleNotFound(Vehicle.ID)
}

public enum ServiceLog {
    /// Inserts the record (with an optional receipt photo) for the vehicle and saves.
    ///
    /// The work happens in a fresh `ModelContext` of `container`, so a failed save is simply
    /// discarded with that context and never touches unsaved changes in the caller's context.
    /// After a successful save, other contexts of the container see the new record.
    ///
    /// The vehicle's own `mileageKm` is left alone: the current mileage is derived from the records.
    public static func add(
        _ record: ServiceRecord,
        receiptImage: Data? = nil,
        toVehicleWithID vehicleID: Vehicle.ID,
        in container: ModelContainer
    ) throws {
        try add(record, receiptImage: receiptImage, toVehicleWithID: vehicleID, in: container) { try $0.save() }
    }

    /// `add` with an injectable save step, so tests can simulate a failing save.
    static func add(
        _ record: ServiceRecord,
        receiptImage: Data?,
        toVehicleWithID vehicleID: Vehicle.ID,
        in container: ModelContainer,
        save: (ModelContext) throws -> Void
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<VehicleEntity>(predicate: #Predicate { $0.id == vehicleID })
        descriptor.fetchLimit = 1
        guard let vehicle = try context.fetch(descriptor).first else {
            throw ServiceLogError.vehicleNotFound(vehicleID)
        }
        let entity = try ServiceRecordEntity(record, vehicle: vehicle)
        entity.setReceiptImage(receiptImage)
        context.insert(entity)
        try SyncQueue.enqueueUpsert(.serviceRecord(record, entity.syncExtras), in: context)
        try save(context)
    }
}

public enum VehicleLog {
    /// Inserts the vehicle and queues it for sync, in one save.
    ///
    /// Like `ServiceLog.add`, the work happens in a fresh `ModelContext` of `container`.
    public static func add(_ vehicle: Vehicle, in container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(VehicleEntity(vehicle))
        try SyncQueue.enqueueUpsert(.vehicle(vehicle), in: context)
        try context.save()
    }
}
