import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData
import Testing

@testable import GarageStorage

private let vehicleVersion: Int64 = 5

private func vehicleRef(_ id: Vehicle.ID) -> EntityRef { EntityRef(kind: .vehicle, id: id) }
private func recordRef(_ id: ServiceRecord.ID) -> EntityRef { EntityRef(kind: .serviceRecord, id: id) }

/// Контейнер с машиной; `synced == true` имитирует уже отправленную на сервер машину (очередь пуста, версия 5).
private func makeVehicleStore(synced: Bool) throws -> (container: ModelContainer, vehicle: Vehicle) {
    let container = try GarageStore.makeContainer(inMemory: true)
    let vehicle = Vehicle.samples[0]
    try VehicleLog.add(vehicle, in: container)
    if synced { try markSynced(container, vehicle: vehicle, records: []) }
    return (container, vehicle)
}

/// Убирает всю очередь и запоминает версии машины и записей, как после успешного sync.
private func markSynced(_ container: ModelContainer, vehicle: Vehicle, records: [ServiceRecord]) throws {
    let context = ModelContext(container)
    for pending in try context.fetch(FetchDescriptor<PendingChangeEntity>()) { context.delete(pending) }
    try SyncState.setVersion(vehicleVersion, for: vehicleRef(vehicle.id), in: context)
    for (index, record) in records.enumerated() {
        try SyncState.setVersion(vehicleVersion + 1 + Int64(index), for: recordRef(record.id), in: context)
    }
    try context.save()
}

private func edited(_ vehicle: Vehicle, make: String = "Lexus") throws -> Vehicle {
    try Vehicle(
        id: vehicle.id, kind: vehicle.kind, make: make, model: vehicle.model, year: vehicle.year,
        mileageKm: vehicle.mileageKm + 10)
}

private func storedVehicle(_ id: Vehicle.ID, in container: ModelContainer) throws -> VehicleEntity? {
    try ModelContext(container).fetch(FetchDescriptor<VehicleEntity>()).first { $0.id == id }
}

private func count<T: PersistentModel>(_ type: T.Type, in container: ModelContainer) throws -> Int {
    try ModelContext(container).fetchCount(FetchDescriptor<T>())
}

private func pendingSequence(_ ref: EntityRef, in container: ModelContainer) throws -> Int64? {
    let context = ModelContext(container)
    let pending = try SyncState.pendingEntity(for: ref, in: context)
    return pending?.sequence
}

private struct Boom: Error {}

@Suite struct VehicleLogTests {
    // MARK: Add / update

    @Test func addStoresVehicleAndQueuesUpsertInOneSave() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[1]

        try VehicleLog.add(vehicle, in: container)

        #expect(try #require(try storedVehicle(vehicle.id, in: container)).toDomain() == vehicle)
        let pending = try await pendingChanges(container)
        #expect(pending.count == 1 && pending[0].baseVersion == nil)
        #expect(pending[0].operation == .upsert(.vehicle(vehicle)))
    }

    @Test func updateReplacesFieldsAndQueuesUpsertWithBaseVersion() async throws {
        let (container, vehicle) = try makeVehicleStore(synced: true)
        let changed = try edited(vehicle)

        try VehicleLog.update(changed, in: container)

        #expect(try #require(try storedVehicle(vehicle.id, in: container)).toDomain() == changed)
        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].baseVersion == vehicleVersion)
        #expect(pending[0].operation == .upsert(.vehicle(changed)))
    }

    @Test func twoUpdatesCollapseKeepingBaseVersion() async throws {
        let (container, vehicle) = try makeVehicleStore(synced: true)
        try VehicleLog.update(try edited(vehicle, make: "A"), in: container)
        let first = try await pendingChanges(container)
        let last = try edited(vehicle, make: "B")

        try VehicleLog.update(last, in: container)

        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].baseVersion == vehicleVersion)
        #expect(pending[0].changeID != first[0].changeID)
        #expect(pending[0].operation == .upsert(.vehicle(last)))
    }

    @Test func updateOfMissingVehicleThrowsAndQueuesNothing() async throws {
        let (container, vehicle) = try makeVehicleStore(synced: true)
        let other = try edited(Vehicle.samples[1])

        #expect(throws: ServiceLogError.vehicleNotFound(other.id)) {
            try VehicleLog.update(other, in: container)
        }
        #expect(try await pendingChanges(container).isEmpty)
        #expect(try #require(try storedVehicle(vehicle.id, in: container)).make == vehicle.make)
    }

    @Test func failedSaveChangesNothing() async throws {
        let (container, vehicle) = try makeVehicleStore(synced: true)

        #expect(throws: Boom.self) {
            try VehicleLog.add(Vehicle.samples[1], in: container) { _ in throw Boom() }
        }
        #expect(throws: Boom.self) {
            try VehicleLog.update(try edited(vehicle), in: container) { _ in throw Boom() }
        }
        #expect(throws: Boom.self) {
            try VehicleLog.delete(id: vehicle.id, in: container) { _ in throw Boom() }
        }

        #expect(try count(VehicleEntity.self, in: container) == 1)
        #expect(try #require(try storedVehicle(vehicle.id, in: container)).make == vehicle.make)
        #expect(try await pendingChanges(container).isEmpty)
    }

    // MARK: Delete

    @Test func deleteOfMissingVehicleIsQuietNoOp() async throws {
        let (container, _) = try makeVehicleStore(synced: true)

        try await SwiftDataVehicleRepository(container: container).delete(id: UUID())

        #expect(try count(VehicleEntity.self, in: container) == 1)
        #expect(try await pendingChanges(container).isEmpty)
    }

    /// Пункт 1 плана: каскад на сервере делает сам сервер, поэтому в очередь идёт только delete машины.
    @Test func deleteQueuesOnlyVehicleDelete() async throws {
        let (container, vehicle) = try makeVehicleStore(synced: true)
        var records: [ServiceRecord] = []
        for index in 0..<3 {
            let part = try Part(name: "Фильтр", unitPrice: Money(rubles: 50), quantity: 1)
            let record = try ServiceRecord(
                vehicleID: vehicle.id, date: Date(timeIntervalSince1970: 1_700_000_000), mileageKm: 1000,
                serviceType: .oilChange, laborCost: Money(rubles: 100), notes: "r\(index)", parts: [part])
            records.append(record)
            try ServiceLog.add(record, receiptImage: Data([UInt8(index)]), toVehicleWithID: vehicle.id, in: container)
        }
        #expect(try count(PartEntity.self, in: container) == 3)
        try markSynced(container, vehicle: vehicle, records: records)

        try VehicleLog.delete(id: vehicle.id, in: container)

        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].baseVersion == vehicleVersion)
        #expect(pending[0].operation == .delete(vehicleRef(vehicle.id)))
        #expect(try count(VehicleEntity.self, in: container) == 0)
        #expect(try count(ServiceRecordEntity.self, in: container) == 0)
        #expect(try count(PartEntity.self, in: container) == 0)
    }

    @Test func deleteWithoutVersionStillQueuesDelete() async throws {
        let (container, vehicle) = try makeVehicleStore(synced: false)
        let context = ModelContext(container)
        for pending in try context.fetch(FetchDescriptor<PendingChangeEntity>()) { context.delete(pending) }
        try context.save()

        try VehicleLog.delete(id: vehicle.id, in: container)

        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].baseVersion == nil)
        #expect(pending[0].operation == .delete(vehicleRef(vehicle.id)))
    }

    @Test func deleteOfUnsentVehicleCollapsesIntoDelete() async throws {
        let (container, vehicle) = try makeVehicleStore(synced: false)
        try ServiceLog.add(
            try makeSyncRecord(for: vehicle), receiptImage: Data([1]), toVehicleWithID: vehicle.id, in: container)
        let sequence = try #require(try pendingSequence(vehicleRef(vehicle.id), in: container))
        #expect(try await pendingChanges(container).count == 2)

        try VehicleLog.delete(id: vehicle.id, in: container)

        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].baseVersion == nil)
        #expect(pending[0].operation == .delete(vehicleRef(vehicle.id)))
        #expect(try pendingSequence(vehicleRef(vehicle.id), in: container) == sequence)
    }

    /// Пункт 2 плана: pending-upsert'ы записей снимаются, pending-delete остаются.
    @Test func deleteDropsPendingRecordUpsertsKeepsDeletes() async throws {
        let (container, vehicle) = try makeVehicleStore(synced: false)
        let r1 = try makeSyncRecord(for: vehicle, notes: "правка")
        let r3 = try makeSyncRecord(for: vehicle, notes: "удалена")
        try ServiceLog.add(r1, toVehicleWithID: vehicle.id, in: container)
        try ServiceLog.add(r3, toVehicleWithID: vehicle.id, in: container)
        try markSynced(container, vehicle: vehicle, records: [r1, r3])
        try ServiceLog.delete(id: r3.id, in: container)
        try ServiceLog.update(
            try ServiceRecord(
                id: r1.id, vehicleID: vehicle.id, date: r1.date, mileageKm: 2000, serviceType: .brakes,
                laborCost: r1.laborCost, notes: "после"),
            receipt: .keep, in: container)
        let r2 = try makeSyncRecord(for: vehicle, notes: "новая")
        try ServiceLog.add(r2, receiptImage: Data([9]), toVehicleWithID: vehicle.id, in: container)
        #expect(
            try await pendingChanges(container).map(\.operation.ref) == [
                recordRef(r3.id), recordRef(r1.id), recordRef(r2.id),
            ])

        try VehicleLog.delete(id: vehicle.id, in: container)

        let pending = try await pendingChanges(container)
        #expect(pending.map(\.operation.ref) == [recordRef(r3.id), vehicleRef(vehicle.id)])
        #expect(pending.allSatisfy { $0.operation.isDelete })
        #expect(try count(ServiceRecordEntity.self, in: container) == 0)
    }

    /// Пункт 5 плана: байты чека удаляются вместе с машиной, а общий с другой машиной чек остаётся.
    @Test func deleteRemovesReceiptBytes() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let doomed = Vehicle.samples[0]
        let survivor = Vehicle.samples[1]
        try VehicleLog.add(doomed, in: container)
        try VehicleLog.add(survivor, in: container)
        let onlyHere = Data([1, 1, 1])
        let shared = Data([2, 2, 2])
        try ServiceLog.add(
            try makeSyncRecord(for: doomed), receiptImage: onlyHere, toVehicleWithID: doomed.id, in: container)
        try ServiceLog.add(
            try makeSyncRecord(for: doomed), receiptImage: shared, toVehicleWithID: doomed.id, in: container)
        try ServiceLog.add(
            try makeSyncRecord(for: survivor), receiptImage: shared, toVehicleWithID: survivor.id, in: container)
        let store = SwiftDataSyncStore(modelContainer: container)
        #expect(try await store.receiptData(sha256: ServiceRecordEntity.sha256Hex(onlyHere)) == onlyHere)

        try VehicleLog.delete(id: doomed.id, in: container)

        #expect(try await store.receiptData(sha256: ServiceRecordEntity.sha256Hex(onlyHere)) == nil)
        #expect(try await store.receiptData(sha256: ServiceRecordEntity.sha256Hex(shared)) == shared)
        #expect(try count(ServiceRecordEntity.self, in: container) == 1)
    }
}
