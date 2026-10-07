import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData
import Testing

@testable import GarageStorage

/// Учётные данные в памяти.
private final class MemoryCredentials: SyncCredentialsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var url: URL?

    init(token: String? = "t", url: URL? = URL(string: "https://example.com")) {
        self.token = token
        self.url = url
    }

    func readToken() -> String? { lock.withLock { token } }
    func saveToken(_ token: String) throws { lock.withLock { self.token = token } }
    func deleteToken() { lock.withLock { token = nil } }
    func readServerURL() -> URL? { lock.withLock { url } }
    func saveServerURL(_ url: URL) { lock.withLock { self.url = url } }
    func deleteServerURL() { lock.withLock { url = nil } }
}

/// Транспорт, который «зависает» до отмены.
/// Сообщает, что запрос ушёл в транспорт, чтобы тест отменял задачу строго во время запроса.
private actor HangingTransport: HTTPTransport {
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        didStart = true
        started?.resume()
        started = nil
        try await Task.sleep(for: .seconds(60))
        throw URLError(.timedOut)
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }
}

/// Как URLSession при отмене: бросает `URLError.cancelled`, а не `CancellationError`.
private actor URLCancelledTransport: HTTPTransport {
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var release: CheckedContinuation<Void, Never>?

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        didStart = true
        started?.resume()
        started = nil
        await withCheckedContinuation { release = $0 }
        throw URLError(.cancelled)
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        release?.resume()
        release = nil
    }
}

@Suite struct RepositoryAdapterTests {
    @Test func repositoryAddsRecordAndQueuesIt() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: container)
        let record = try makeSyncRecord(for: vehicle, notes: "ТО")

        try await SwiftDataServiceRecordRepository(container: container).add(record, receiptImage: nil)

        let records = try ModelContext(container).fetch(FetchDescriptor<ServiceRecordEntity>())
        #expect(records.map(\.id) == [record.id])
        let pending = try await pendingChanges(container)
        #expect(pending.contains { $0.operation.ref == EntityRef(kind: .serviceRecord, id: record.id) })
    }

    @Test func repositoryMapsMissingVehicle() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let record = try makeSyncRecord(for: Vehicle.samples[0])

        await #expect(throws: RepositoryError.vehicleNotFound(record.vehicleID)) {
            try await SwiftDataServiceRecordRepository(container: container).add(record, receiptImage: nil)
        }
    }
}

@Suite struct SyncServiceTests {
    private func makeService(
        _ container: ModelContainer, credentials: MemoryCredentials = MemoryCredentials(),
        transport: any HTTPTransport
    ) -> SwiftDataSyncService {
        SwiftDataSyncService(container: container, credentials: credentials, makeTransport: { _ in transport })
    }

    @Test func syncStatusAndResetWork() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        try VehicleLog.add(Vehicle.samples[0], in: container)
        let server = FakeSyncServer()
        let service = makeService(container, transport: server)

        let before = try await service.status()
        #expect(before.pendingCount == 1 && before.lastSyncAt == nil)

        let summary = try await service.sync()
        #expect(summary == SyncSummary())
        let after = try await service.status()
        #expect(after.pendingCount == 0 && after.lastSyncAt != nil)

        try await service.resetSyncState()
        let reset = try await service.status()
        #expect(reset.lastSyncAt == nil)
        // После сброса данные снова ставятся в очередь (bootstrap).
        #expect(reset.pendingCount == 1)
    }

    @Test func syncWithoutCredentialsIsNotRegistered() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let service = makeService(container, credentials: MemoryCredentials(token: nil), transport: FakeSyncServer())

        await #expect(throws: SyncFailure.notRegistered) { try await service.sync() }
    }

    @Test func serverErrorMapsToFailure() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        // Пустой сервер, но с неизвестным путём: подменяем транспорт, который всегда 401.
        struct Unauthorized: HTTPTransport {
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                HTTPResponse(
                    status: 401,
                    body: try APICoding.makeEncoder().encode(
                        APIErrorResponse(error: APIError(code: .unauthorized, message: "x"))))
            }
        }
        let service = makeService(container, transport: Unauthorized())

        await #expect(throws: SyncFailure.unauthorized) { try await service.sync() }
    }

    @Test func cancellationDuringHungRequestThrowsCancellationError() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let transport = HangingTransport()
        let service = makeService(container, transport: transport)

        let task = Task { try await service.sync() }
        await transport.waitUntilStarted()
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await service.status().lastSyncAt == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func urlErrorCancelledOnCancelledTaskMapsToCancellationError() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let transport = URLCancelledTransport()
        let service = makeService(container, transport: transport)

        let task = Task { try await service.sync() }
        await transport.waitUntilStarted()
        task.cancel()
        await transport.finish()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite struct DisplayMappingTests {
    @Test func validVehiclesSkipsBrokenEntity() throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let good = VehicleEntity(Vehicle.samples[0])
        let broken = VehicleEntity(Vehicle.samples[1])
        context.insert(good)
        context.insert(broken)
        broken.kindRaw = "boat"
        let record = try ServiceRecordEntity(makeSyncRecord(for: Vehicle.samples[0]), vehicle: good)
        context.insert(record)

        let items = [good, broken].validVehicles()

        #expect(items.map(\.id) == [Vehicle.samples[0].id])
        #expect(items[0].recordCount == 1)
    }

    @Test func validRecordsSkipsBrokenEntity() throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let vehicle = VehicleEntity(Vehicle.samples[0])
        context.insert(vehicle)
        let good = try ServiceRecordEntity(makeSyncRecord(for: Vehicle.samples[0]), vehicle: vehicle)
        let broken = try ServiceRecordEntity(makeSyncRecord(for: Vehicle.samples[0]), vehicle: vehicle)
        context.insert(good)
        context.insert(broken)
        broken.mileageKm = -5

        #expect([good, broken].validRecords().map(\.id) == [good.id])
    }
}

@Suite struct AppBootstrapTests {
    @Test func prepareIsIdempotentOnInMemoryStore() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!

        let container = try await AppBootstrap.prepare(inMemory: true, defaults: defaults)
        try SampleSeeder.seedIfNeeded(container, defaults: defaults)
        try SyncSupport.prepare(container)

        #expect(try ModelContext(container).fetchCount(FetchDescriptor<VehicleEntity>()) == 4)
        #expect(try await pendingChanges(container).count == 4)
    }

    @Test func receiptPreparerRejectsGarbage() async {
        await #expect(throws: ReceiptImageError.unreadableImage) {
            try await ImageIOReceiptPreparer().prepare(Data([1, 2, 3]))
        }
    }
}
