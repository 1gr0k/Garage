import Foundation
import GarageCore
import GarageSync
import SwiftData

public enum ServiceLogError: Error, Hashable, Sendable {
    case vehicleNotFound(Vehicle.ID)
    case recordNotFound(ServiceRecord.ID)
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

    /// Заменяет поля записи с тем же `id` и ставит upsert в очередь синхронизации, в одном сохранении.
    ///
    /// Работает в свежем `ModelContext`, как `add`. Чек меняется только через `setReceiptImage`.
    public static func update(
        _ record: ServiceRecord,
        receipt: ReceiptChange,
        in container: ModelContainer
    ) throws {
        try update(record, receipt: receipt, in: container) { try $0.save() }
    }

    /// `update` с подменяемым сохранением, чтобы тесты могли имитировать сбой.
    static func update(
        _ record: ServiceRecord,
        receipt: ReceiptChange,
        in container: ModelContainer,
        save: (ModelContext) throws -> Void
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let entity = try recordEntity(id: record.id, in: context) else {
            throw ServiceLogError.recordNotFound(record.id)
        }
        entity.update(from: record)
        // Неизвестный серверный тип живёт в `rawServiceType`; если тип сменили, он не должен воскреснуть.
        if let raw = entity.rawServiceType, record.serviceType != .other(raw) {
            entity.rawServiceType = nil
        }
        switch receipt {
        case .keep: break
        case .replace(let data): entity.setReceiptImage(data)
        case .remove: entity.setReceiptImage(nil)
        }
        // После чека: в extras должен попасть актуальный `ReceiptRefDTO`.
        try SyncQueue.enqueueUpsert(.serviceRecord(record, entity.syncExtras), in: context)
        try save(context)
    }

    /// Удаляет запись (части — каскадом, чек — вместе с сущностью) и ставит delete в очередь, в одном
    /// сохранении. Записи нет — не ошибка.
    public static func delete(id: ServiceRecord.ID, in container: ModelContainer) throws {
        try delete(id: id, in: container) { try $0.save() }
    }

    /// `delete` с подменяемым сохранением, чтобы тесты могли имитировать сбой.
    static func delete(
        id: ServiceRecord.ID,
        in container: ModelContainer,
        save: (ModelContext) throws -> Void
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let entity = try recordEntity(id: id, in: context) else { return }
        // Delete ставится всегда, даже без `SyncVersionEntity`: её отсутствие не значит «на сервере записи нет»
        // (push в полёте, сброс версий при смене схемы или «Забыть устройство»). Pending-правка схлопывается в delete.
        try SyncQueue.enqueueDelete(EntityRef(kind: .serviceRecord, id: id), in: context)
        context.delete(entity)
        try save(context)
    }

    private static func recordEntity(id: ServiceRecord.ID, in context: ModelContext) throws -> ServiceRecordEntity? {
        var descriptor = FetchDescriptor<ServiceRecordEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
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
