import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData
import Testing

@testable import GarageStorage

private func vehicleRef(_ vehicle: Vehicle) -> EntityRef { EntityRef(kind: .vehicle, id: vehicle.id) }

@Suite struct SwiftDataSyncStoreTests {
    @Test func markAppliedDropsQueueEntryAndRemembersVersion() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: container)
        let store = SwiftDataSyncStore(modelContainer: container)
        let change = try #require(await store.pendingChanges().first)

        try await store.markApplied(changeID: change.changeID, version: 5)

        #expect(try await store.pendingChanges().isEmpty)
        #expect(try await store.version(of: vehicleRef(vehicle)) == 5)
    }

    @Test func rebaseChangesOnlyBaseVersion() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: container)
        let store = SwiftDataSyncStore(modelContainer: container)
        let change = try #require(await store.pendingChanges().first)

        try await store.rebase(changeID: change.changeID, onto: 9)

        let rebased = try #require(await store.pendingChange(for: vehicleRef(vehicle)))
        #expect(rebased.baseVersion == 9)
        #expect(rebased.operation == change.operation)
        #expect(try await store.version(of: vehicleRef(vehicle)) == nil)
    }

    @Test func discardDropsQueueEntryOnly() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        try VehicleLog.add(Vehicle.samples[0], in: container)
        let store = SwiftDataSyncStore(modelContainer: container)
        let change = try #require(await store.pendingChanges().first)

        try await store.discard(changeID: change.changeID)

        #expect(try await store.pendingChanges().isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<VehicleEntity>()) == 1)
    }

    @Test func cursorAndLastSyncPersist() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let store = SwiftDataSyncStore(modelContainer: container)
        #expect(try await store.cursor() == nil)
        try await store.setCursor("42")
        let finished = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.recordSyncFinished(at: finished)

        let other = SwiftDataSyncStore(modelContainer: container)
        #expect(try await other.cursor() == "42")
        #expect(try await other.lastSyncAt() == finished)
    }

    @Test func applyUpsertsVehicleAndRecordAndClearsPending() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: container)
        let store = SwiftDataSyncStore(modelContainer: container)
        var renamed = vehicle
        renamed.make = "Lexus"
        try await store.apply(
            RemoteChange(version: 3, operation: .upsert(.vehicle(renamed))), for: vehicleRef(vehicle))
        let record = try makeSyncRecord(for: vehicle)
        let extras = RecordSyncExtras(
            receipt: ReceiptRefDTO(sha256: String(repeating: "c", count: 64), byteCount: 4), rawServiceType: "newType")
        try await store.apply(
            RemoteChange(version: 4, operation: .upsert(.serviceRecord(record, extras))),
            for: EntityRef(kind: .serviceRecord, id: record.id))

        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<VehicleEntity>()).first?.make == "Lexus")
        let entity = try #require(context.fetch(FetchDescriptor<ServiceRecordEntity>()).first)
        #expect(entity.vehicle?.id == vehicle.id)
        #expect(entity.rawServiceType == "newType")
        #expect(entity.hasReceipt && entity.receiptNeedsDownload && entity.receiptImage == nil)
        #expect(try await store.pendingChanges().isEmpty)
        #expect(try await store.version(of: vehicleRef(vehicle)) == 3)
    }

    @Test func applyRecordWithoutVehicleIsCannotApplyAndChangesNothing() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let store = SwiftDataSyncStore(modelContainer: container)
        let record = try makeSyncRecord(for: Vehicle.samples[0])
        let ref = EntityRef(kind: .serviceRecord, id: record.id)

        await #expect(throws: SyncStoreError.self) {
            try await store.apply(
                RemoteChange(version: 2, operation: .upsert(.serviceRecord(record, RecordSyncExtras()))), for: ref)
        }
        #expect(try await store.version(of: ref) == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<ServiceRecordEntity>()) == 0)
    }

    @Test func deleteCascadesAndKeepsTombstoneVersion() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: container)
        try ServiceLog.add(
            try makeSyncRecord(for: vehicle), toVehicleWithID: vehicle.id, in: container)
        let store = SwiftDataSyncStore(modelContainer: container)

        try await store.apply(
            RemoteChange(version: 8, operation: .delete(vehicleRef(vehicle))), for: vehicleRef(vehicle))

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<VehicleEntity>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ServiceRecordEntity>()) == 0)
        #expect(try await store.version(of: vehicleRef(vehicle)) == 8)
        // The vehicle's pending upsert is gone; the record's stays until the engine settles it.
        #expect(try await store.pendingChange(for: vehicleRef(vehicle)) == nil)
    }

    @Test func localOnlyDeleteLeavesVersionUntouched() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: container)
        let store = SwiftDataSyncStore(modelContainer: container)
        let change = try #require(await store.pendingChanges().first)
        try await store.markApplied(changeID: change.changeID, version: 2)

        try await store.apply(
            RemoteChange(version: nil, operation: .delete(vehicleRef(vehicle))), for: vehicleRef(vehicle))

        #expect(try await store.version(of: vehicleRef(vehicle)) == 2)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<VehicleEntity>()) == 0)
    }

    @Test func schemaVersionChangeResetsCursorAndVersionsButKeepsPending() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let synced = Vehicle.samples[0]
        let edited = Vehicle.samples[1]
        let store = SwiftDataSyncStore(modelContainer: container)
        try VehicleLog.add(synced, in: container)
        let change = try #require(await store.pendingChanges().first)
        try await store.markApplied(changeID: change.changeID, version: 5)
        try ModelContext(container).perform { context in
            try SyncState.setVersion(6, for: vehicleRef(edited), in: context)
            try SyncQueue.enqueueUpsert(.vehicle(edited), in: context)
            try context.save()
        }
        try await store.setCursor("9")
        let context = ModelContext(container)
        try SyncState.current(in: context).schemaVersion = GarageStore.schemaVersion - 1
        try context.save()

        try SyncSupport.prepare(container)

        #expect(try await store.cursor() == nil)
        #expect(try await store.version(of: vehicleRef(synced)) == nil)
        #expect(try await store.version(of: vehicleRef(edited)) == 6)
        #expect(try await store.pendingChange(for: vehicleRef(edited))?.baseVersion == 6)
        #expect(try SyncState.current(in: ModelContext(container)).schemaVersion == GarageStore.schemaVersion)
    }

    @Test func resetSyncStateForgetsServerAndRequeuesEverything() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        SampleSeeder.insertSamples(into: context)
        try context.save()
        try SyncSupport.prepare(container)
        let store = SwiftDataSyncStore(modelContainer: container)
        for change in try await store.pendingChanges() {
            try await store.markApplied(changeID: change.changeID, version: 4)
        }
        try await store.setCursor("9")
        #expect(try await store.pendingChanges().isEmpty)

        try SyncSupport.resetSyncState(container)

        #expect(try await store.cursor() == nil)
        let pending = try await store.pendingChanges()
        #expect(pending.count == 4)
        #expect(pending.allSatisfy { $0.baseVersion == nil })
        #expect(try await store.version(of: vehicleRef(Vehicle.samples[0])) == nil)
    }

    @Test func sameSchemaVersionKeepsCursor() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let store = SwiftDataSyncStore(modelContainer: container)
        try await store.setCursor("9")
        try SyncSupport.prepare(container)
        #expect(try await store.cursor() == "9")
    }
}

extension ModelContext {
    fileprivate func perform(_ body: (ModelContext) throws -> Void) throws { try body(self) }
}
