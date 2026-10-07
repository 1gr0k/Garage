import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData
import Testing

@testable import GarageStorage

func makeSyncRecord(for vehicle: Vehicle, id: UUID = UUID(), notes: String = "") throws -> ServiceRecord {
    try ServiceRecord(
        id: id, vehicleID: vehicle.id, date: Date(timeIntervalSince1970: 1_700_000_000), mileageKm: 1000,
        serviceType: .oilChange, laborCost: Money(rubles: 100), notes: notes)
}

func pendingChanges(_ container: ModelContainer) async throws -> [PendingChange] {
    try await SwiftDataSyncStore(modelContainer: container).pendingChanges()
}

@Suite struct SyncQueueTests {
    @Test func vehicleLogAddQueuesCreationWithMillisecondDate() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: container)

        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].baseVersion == nil)
        #expect(pending[0].operation == .upsert(.vehicle(vehicle)))
        let ms = pending[0].modifiedAt.timeIntervalSince1970 * 1000
        #expect(ms == ms.rounded())
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<VehicleEntity>()) == 1)
    }

    @Test func serviceLogAddQueuesRecordWithReceiptExtrasAfterItsVehicle() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: container)
        let record = try makeSyncRecord(for: vehicle)
        let photo = Data([1, 2, 3])
        try ServiceLog.add(record, receiptImage: photo, toVehicleWithID: vehicle.id, in: container)

        let pending = try await pendingChanges(container)
        #expect(pending.map(\.operation.ref.kind) == [.vehicle, .serviceRecord])
        let expected = ReceiptRefDTO(sha256: ServiceRecordEntity.sha256Hex(photo), byteCount: 3)
        #expect(pending[1].operation == .upsert(.serviceRecord(record, RecordSyncExtras(receipt: expected))))
    }

    @Test func failedSaveLeavesNoQueueEntry() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: container)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try ServiceLog.add(
                try makeSyncRecord(for: vehicle), receiptImage: nil, toVehicleWithID: vehicle.id, in: container
            ) { _ in throw Boom() }
        }
        #expect(try await pendingChanges(container).count == 1)
    }

    @Test func newEditReplacesQueuedOneKeepingBaseVersionAndPosition() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let first = Vehicle.samples[0]
        let second = Vehicle.samples[1]
        let context = ModelContext(container)
        try SyncState.setVersion(7, for: EntityRef(kind: .vehicle, id: first.id), in: context)
        try SyncQueue.enqueueUpsert(.vehicle(first), in: context)
        try SyncQueue.enqueueUpsert(.vehicle(second), in: context)
        try context.save()
        let before = try await pendingChanges(container)
        #expect(before[0].baseVersion == 7)
        #expect(before[1].baseVersion == nil)

        var edited = first
        edited.make = "Lexus"
        let editContext = ModelContext(container)
        try SyncQueue.enqueueUpsert(.vehicle(edited), in: editContext)
        try editContext.save()

        let after = try await pendingChanges(container)
        #expect(after.count == 2)
        #expect(after[0].operation == .upsert(.vehicle(edited)))
        #expect(after[0].baseVersion == 7)
        #expect(after[0].changeID != before[0].changeID)
        #expect(after[1] == before[1])
    }

    @Test func deleteReplacesQueuedUpsert() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        let context = ModelContext(container)
        try SyncQueue.enqueueUpsert(.vehicle(vehicle), in: context)
        try SyncQueue.enqueueDelete(EntityRef(kind: .vehicle, id: vehicle.id), in: context)
        try context.save()

        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].operation == .delete(EntityRef(kind: .vehicle, id: vehicle.id)))
    }
}
