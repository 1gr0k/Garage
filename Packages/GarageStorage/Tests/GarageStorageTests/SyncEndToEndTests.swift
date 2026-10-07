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

    /// - Parameter defaults: свои `UserDefaults` устройства; с ними машины сеются как при первом запуске приложения.
    init(seedSamples: Bool = false, defaults: UserDefaults? = nil) throws {
        container = try GarageStore.makeContainer(inMemory: true)
        if let defaults {
            try SampleSeeder.seedIfNeeded(container, defaults: defaults)
        } else if seedSamples {
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

/// Транспорт, который перед первым push вызывает `beforePush`: имитирует правку, сделанную, пока запрос в пути.
private actor DeleteDuringPushTransport: HTTPTransport {
    private let server: FakeSyncServer
    private let beforePush: @Sendable () -> Void
    private var fired = false

    init(server: FakeSyncServer, beforePush: @escaping @Sendable () -> Void) {
        self.server = server
        self.beforePush = beforePush
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await server.send(request)
        if request.method == "POST", !fired {
            fired = true
            beforePush()
        }
        return response
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

    @Test func recordDeletedBeforeFirstSyncEndsDeletedOnServer() async throws {
        let server = FakeSyncServer()
        let device = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: device.container)
        let record = try makeSyncRecord(for: vehicle)
        try ServiceLog.add(record, receiptImage: Data([1]), toVehicleWithID: vehicle.id, in: device.container)

        try ServiceLog.delete(id: record.id, in: device.container)
        _ = try await device.sync(with: server)
        _ = try await device.sync(with: server)

        #expect(await server.liveCount(.vehicle) == 1)
        #expect(await server.liveCount(.serviceRecord) == 0)
        #expect(await server.blobs.isEmpty)
        #expect(try device.records().isEmpty)
        #expect(try await device.store.pendingChanges().isEmpty)
    }

    @Test func recordDeletedWhilePushIsInFlightIsNotResurrected() async throws {
        let server = FakeSyncServer()
        let device = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: device.container)
        let record = try makeSyncRecord(for: vehicle)
        try ServiceLog.add(record, toVehicleWithID: vehicle.id, in: device.container)
        let transport = DeleteDuringPushTransport(server: server) {
            try? ServiceLog.delete(id: record.id, in: device.container)
        }
        let engine = SyncEngine(
            store: device.store, client: SyncAPIClient(transport: transport, token: "t"), receipts: device.store)

        _ = try await engine.sync()
        _ = try await engine.sync()
        _ = try await engine.sync()

        #expect(try device.records().isEmpty)
        #expect(await server.liveCount(.serviceRecord) == 0)
        #expect(try await device.store.pendingChanges().isEmpty)
    }

    // MARK: Удаление машины

    @Test func vehicleDeleteCascadesToAnotherDevice() async throws {
        let server = FakeSyncServer()
        let first = try Device()
        let second = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: first.container)
        for notes in ["раз", "два"] {
            try ServiceLog.add(
                try makeSyncRecord(for: vehicle, notes: notes), toVehicleWithID: vehicle.id, in: first.container)
        }
        _ = try await first.sync(with: server)
        _ = try await second.sync(with: server)
        #expect(try second.vehicles().count == 1 && second.records().count == 2)

        try VehicleLog.delete(id: vehicle.id, in: first.container)
        let report = try await first.sync(with: server)
        _ = try await second.sync(with: server)

        // В очереди был один delete машины; tombstones записей сделал сервер.
        #expect(report.pushed == 1 && report.rejected.isEmpty)
        let pushes = try await server.requests.filter { $0.method == "POST" }.map {
            try APICoding.makeDecoder().decode(PushRequest.self, from: $0.body ?? Data())
        }
        #expect(pushes.last?.changes.map(\.operation) == [.delete(.vehicle, id: vehicle.id)])
        #expect(await server.liveCount(.vehicle) == 0)
        #expect(await server.liveCount(.serviceRecord) == 0)
        #expect(try second.vehicles().isEmpty && second.records().isEmpty)
        #expect(try await first.store.pendingChanges().isEmpty)
        #expect(try await second.store.pendingChanges().isEmpty)
    }

    @Test func deletingVehicleWithUnsyncedRecordPushesWithoutRejections() async throws {
        let server = FakeSyncServer()
        let device = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: device.container)
        _ = try await device.sync(with: server)
        let record = try makeSyncRecord(for: vehicle)
        try ServiceLog.add(record, receiptImage: Data([1, 2, 3]), toVehicleWithID: vehicle.id, in: device.container)

        try VehicleLog.delete(id: vehicle.id, in: device.container)
        let report = try await device.sync(with: server)

        #expect(report.rejected.isEmpty && report.skipped.isEmpty && report.receiptFailures.isEmpty)
        #expect(report.pushed == 1)
        #expect(await server.receiptUploadCount == 0)
        #expect(await server.liveCount(.vehicle) == 0)
        #expect(await server.liveCount(.serviceRecord) == 0)
        #expect(try device.vehicles().isEmpty && device.records().isEmpty)
        #expect(try await device.store.pendingChanges().isEmpty)
    }

    @Test func vehicleDeletedWhilePushIsInFlight() async throws {
        let server = FakeSyncServer()
        let device = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: device.container)
        _ = try await device.sync(with: server)
        let record = try makeSyncRecord(for: vehicle)
        try ServiceLog.add(record, toVehicleWithID: vehicle.id, in: device.container)
        let transport = DeleteDuringPushTransport(server: server) {
            try? VehicleLog.delete(id: vehicle.id, in: device.container)
        }
        let engine = SyncEngine(
            store: device.store, client: SyncAPIClient(transport: transport, token: "t"), receipts: device.store)

        // Первый sync: upsert записи уже ушёл, ответ `applied` ничего не находит по `changeID`.
        _ = try await engine.sync()
        #expect(try await server.liveCount(.serviceRecord) == 1)
        // Второй: уходит delete машины, каскад сервера ставит tombstone записи.
        let second = try await engine.sync()
        _ = try await engine.sync()

        #expect(second.pushed == 1 && second.rejected.isEmpty)
        #expect(try device.vehicles().isEmpty && device.records().isEmpty)
        #expect(await server.liveCount(.vehicle) == 0)
        #expect(await server.liveCount(.serviceRecord) == 0)
        #expect(await server.version(of: .serviceRecord, id: record.id) != nil)
        #expect(try await device.store.pendingChanges().isEmpty)
    }

    @Test func recordAddedToVehicleDeletedOnAnotherDevice() async throws {
        let server = FakeSyncServer()
        let first = try Device()
        let second = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: first.container)
        _ = try await first.sync(with: server)
        _ = try await second.sync(with: server)
        try VehicleLog.delete(id: vehicle.id, in: first.container)
        _ = try await first.sync(with: server)

        try ServiceLog.add(
            try makeSyncRecord(for: vehicle), receiptImage: Data([5]), toVehicleWithID: vehicle.id, in: second.container
        )
        let report = try await second.sync(with: server)

        // Удаление побеждает: запись, добавленная к удалённой машине, теряется без падения sync.
        #expect(report.rejected.map(\.error.code) == [.vehicleNotFound])
        #expect(try second.vehicles().isEmpty && second.records().isEmpty)
        #expect(try await second.store.pendingChangeCount() == 0)
        let again = try await second.sync(with: server)
        #expect(again.pushed == 0 && again.pulled == 0 && again.rejected.isEmpty)
        #expect(await server.liveCount(.vehicle) == 0)
        #expect(await server.liveCount(.serviceRecord) == 0)
    }

    @Test func deletedSampleVehicleStaysDeletedOnNewDevice() async throws {
        let server = FakeSyncServer()
        let first = try Device(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        _ = try await first.sync(with: server)
        try VehicleLog.delete(id: Vehicle.SampleID.landCruiser, in: first.container)
        _ = try await first.sync(with: server)
        let tombstone = try #require(await server.version(of: .vehicle, id: Vehicle.SampleID.landCruiser))

        let second = try Device(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(try second.vehicles().count == 4)
        _ = try await second.sync(with: server)

        #expect(try second.vehicles().count == 3)
        #expect(!(try second.vehicles().contains { $0.id == Vehicle.SampleID.landCruiser }))
        #expect(await server.version(of: .vehicle, id: Vehicle.SampleID.landCruiser) == tombstone)
        #expect(await server.liveCount(.vehicle) == 3)
        #expect(try await second.store.pendingChanges().isEmpty)
    }

    @Test func pendingReceiptDownloadIsDroppedWithVehicle() async throws {
        let server = FakeSyncServer()
        let first = try Device()
        let second = try Device()
        let vehicle = Vehicle.samples[2]
        try VehicleLog.add(vehicle, in: first.container)
        try ServiceLog.add(
            try makeSyncRecord(for: vehicle), receiptImage: Data([4, 5, 6]), toVehicleWithID: vehicle.id,
            in: first.container)
        _ = try await first.sync(with: server)
        await server.blockReceiptDownloads()
        let downloading = Task { try await second.sync(with: server) }
        await server.waitForBlockedDownload()
        #expect(try await second.store.missingReceipts().count == 1)

        try VehicleLog.delete(id: vehicle.id, in: first.container)
        _ = try await first.sync(with: server)
        _ = try await second.sync(with: server)
        #expect(try await second.store.missingReceipts().isEmpty)
        await server.releaseReceiptDownloads()
        let report = try await downloading.value

        #expect(report.receiptFailures.isEmpty)
        #expect(try second.vehicles().isEmpty && second.records().isEmpty)
        #expect(try await second.store.missingReceipts().isEmpty)
        #expect(try await second.store.pendingChanges().isEmpty)
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
