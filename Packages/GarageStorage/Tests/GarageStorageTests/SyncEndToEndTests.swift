import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData
import Testing

@testable import GarageStorage

private struct Device {
    let container: ModelContainer
    let store: SwiftDataSyncStore

    init(seedSamples: Bool = false) throws {
        container = try GarageStore.makeContainer(inMemory: true)
        if seedSamples {
            let context = ModelContext(container)
            SampleSeeder.insertSamples(into: context)
            try context.save()
        }
        try SyncSupport.prepare(container)
        store = SwiftDataSyncStore(modelContainer: container)
    }

    func sync(with server: FakeSyncServer) async throws -> SyncReport {
        let engine = SyncEngine(
            store: store, client: SyncAPIClient(transport: server, token: "t"), receipts: store)
        return try await engine.sync()
    }

    func vehicles() throws -> [VehicleEntity] {
        try ModelContext(container).fetch(FetchDescriptor<VehicleEntity>())
    }

    func records() throws -> [ServiceRecordEntity] {
        try ModelContext(container).fetch(FetchDescriptor<ServiceRecordEntity>())
    }
}

@Suite struct SyncEndToEndTests {
    @Test func localEditsReachTheServerAndAnotherDeviceWithReceipt() async throws {
        let server = FakeSyncServer()
        let first = try Device()
        let second = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: first.container)
        let record = try makeSyncRecord(for: vehicle, notes: "Заменено масло")
        let photo = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try ServiceLog.add(record, receiptImage: photo, toVehicleWithID: vehicle.id, in: first.container)

        let report = try await first.sync(with: server)

        #expect(report.pushed == 2)
        #expect(report.stillPending.isEmpty && report.receiptFailures.isEmpty)
        #expect(try await first.store.pendingChanges().isEmpty)
        #expect(await server.liveCount(.vehicle) == 1)
        #expect(await server.liveCount(.serviceRecord) == 1)
        let methods = await server.requests.map(\.method)
        #expect(methods.first == "PUT")

        let pulled = try await second.sync(with: server)

        #expect(pulled.pulled == 2)
        #expect(try second.vehicles().map(\.id) == [vehicle.id])
        let received = try #require(second.records().first)
        #expect(received.notes == "Заменено масло")
        #expect(received.receiptImage == photo)
        #expect(!received.receiptNeedsDownload)
        #expect(try await second.store.pendingChanges().isEmpty)
    }

    @Test func secondSyncWithNothingNewIsQuiet() async throws {
        let server = FakeSyncServer()
        let device = try Device(seedSamples: true)
        _ = try await device.sync(with: server)
        let again = try await device.sync(with: server)

        #expect(again.pushed == 0 && again.pulled == 0 && again.conflictsResolved == 0)
        #expect(try await device.store.pendingChanges().isEmpty)
    }

    @Test func twoDevicesWithSampleDataConvergeOnFourVehicles() async throws {
        let server = FakeSyncServer()
        let first = try Device(seedSamples: true)
        let second = try Device(seedSamples: true)

        let r1 = try await first.sync(with: server)
        let r2 = try await second.sync(with: server)

        #expect(r1.pushed == 4)
        #expect(await server.liveCount(.vehicle) == 4)
        // The second device's creations collide with identical server content: counted as applied.
        #expect(r2.pushed == 4)
        #expect(r2.stillPending.isEmpty && r2.rejected.isEmpty && r2.skipped.isEmpty)
        #expect(try await second.store.pendingChanges().isEmpty)
        #expect(try first.vehicles().count == 4 && second.vehicles().count == 4)
        #expect(Set(try second.vehicles().map(\.id)) == Set(Vehicle.samples.map(\.id)))
        for sample in Vehicle.samples {
            let ref = EntityRef(kind: .vehicle, id: sample.id)
            #expect(try await second.store.version(of: ref) == first.store.version(of: ref))
        }
    }

    @Test func editWithNewReceiptReachesServerAndAnotherDevice() async throws {
        let server = FakeSyncServer()
        let first = try Device()
        let second = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: first.container)
        let record = try makeSyncRecord(for: vehicle, notes: "до")
        try ServiceLog.add(record, receiptImage: Data([1, 2]), toVehicleWithID: vehicle.id, in: first.container)
        _ = try await first.sync(with: server)
        _ = try await second.sync(with: server)

        let photo = Data([7, 7, 7])
        let changed = try ServiceRecord(
            id: record.id, vehicleID: vehicle.id, date: record.date, mileageKm: 2000, serviceType: .brakes,
            laborCost: record.laborCost, notes: "после")
        try ServiceLog.update(changed, receipt: .replace(photo), in: first.container)
        let baseVersion = try #require(try await first.store.pendingChanges().first?.baseVersion)
        let report = try await first.sync(with: server)
        _ = try await second.sync(with: server)

        #expect(report.pushed == 1 && report.stillPending.isEmpty && report.receiptFailures.isEmpty)
        #expect(await server.blobs[ServiceRecordEntity.sha256Hex(photo)] == photo)
        #expect(baseVersion > 0)
        let received = try #require(second.records().first)
        #expect(try received.toDomain() == changed)
        #expect(received.receiptImage == photo)
    }

    @Test func deleteReachesServerAndAnotherDevice() async throws {
        let server = FakeSyncServer()
        let first = try Device()
        let second = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: first.container)
        let record = try makeSyncRecord(for: vehicle)
        try ServiceLog.add(record, toVehicleWithID: vehicle.id, in: first.container)
        _ = try await first.sync(with: server)
        _ = try await second.sync(with: server)
        #expect(try second.records().count == 1)

        try ServiceLog.delete(id: record.id, in: first.container)
        _ = try await first.sync(with: server)
        _ = try await second.sync(with: server)

        #expect(await server.liveCount(.serviceRecord) == 0)
        #expect(try first.records().isEmpty && second.records().isEmpty)
        #expect(try await first.store.pendingChanges().isEmpty)
    }

    @Test func recordDeletedBeforeFirstSyncNeverReachesServer() async throws {
        let server = FakeSyncServer()
        let device = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: device.container)
        let record = try makeSyncRecord(for: vehicle)
        try ServiceLog.add(record, receiptImage: Data([1]), toVehicleWithID: vehicle.id, in: device.container)

        try ServiceLog.delete(id: record.id, in: device.container)
        let report = try await device.sync(with: server)

        #expect(report.pushed == 1)
        #expect(await server.liveCount(.vehicle) == 1)
        #expect(await server.liveCount(.serviceRecord) == 0)
        #expect(await server.blobs.isEmpty)
        #expect(try await device.store.pendingChanges().isEmpty)
    }

    @Test func tombstoneIsNotResurrectedByOlderUpsert() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let store = SwiftDataSyncStore(modelContainer: container)
        let vehicle = Vehicle.samples[0]
        let ref = EntityRef(kind: .vehicle, id: vehicle.id)
        let server = FakeSyncServer()
        let engine = SyncEngine(store: store, client: SyncAPIClient(transport: server, token: "t"), receipts: store)
        try VehicleLog.add(vehicle, in: container)
        _ = try await engine.sync()
        let context = ModelContext(container)
        try SyncQueue.enqueueDelete(ref, in: context)
        context.delete(try #require(context.fetch(FetchDescriptor<VehicleEntity>()).first))
        try context.save()

        _ = try await engine.sync()
        _ = try await engine.sync()

        #expect(try context.fetchCount(FetchDescriptor<VehicleEntity>()) == 0)
        #expect(try await store.pendingChanges().isEmpty)
        #expect(await server.liveCount(.vehicle) == 0)
    }
}
