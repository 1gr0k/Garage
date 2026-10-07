import Foundation
import GarageCore

@testable import Garage

/// Двусторонний барьер: тест ждёт, пока код «дойдёт» до точки, и сам решает, когда его отпустить.
actor Gate {
    private var arrived = false
    private var opened = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrived = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        if opened { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func open() {
        opened = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

struct TestFailure: Error {}

actor FakeRecordRepository: ServiceRecordRepository, ServiceRecordEditing {
    private(set) var added: [(record: ServiceRecord, receipt: Data?)] = []
    private(set) var updated: [(record: ServiceRecord, receipt: ReceiptChange)] = []
    private(set) var deleted: [ServiceRecord.ID] = []
    private var error: (any Error)?
    private var updateError: (any Error)?
    private var deleteError: (any Error)?
    private var deleteGate: Gate?

    /// Ошибка для `add`.
    func failWith(_ error: (any Error)?) { self.error = error }
    func failUpdate(with error: (any Error)?) { updateError = error }
    func failDelete(with error: (any Error)?) { deleteError = error }
    /// `delete` будет ждать, пока тест не откроет барьер.
    func holdDelete(at gate: Gate) { deleteGate = gate }

    func add(_ record: ServiceRecord, receiptImage: Data?) async throws {
        if let error { throw error }
        added.append((record, receiptImage))
    }

    func update(_ record: ServiceRecord, receipt: ReceiptChange) async throws {
        if let updateError { throw updateError }
        updated.append((record, receipt))
    }

    func delete(id: ServiceRecord.ID) async throws {
        deleted.append(id)
        if let deleteGate { await deleteGate.arriveAndWait() }
        if let deleteError { throw deleteError }
    }
}

actor FakeVehicleRepository: VehicleRepository {
    private(set) var added: [Vehicle] = []
    private(set) var updated: [Vehicle] = []
    private(set) var deleted: [Vehicle.ID] = []
    private var addError: (any Error)?
    private var updateError: (any Error)?
    private var deleteError: (any Error)?
    private var addGate: Gate?
    private var deleteGate: Gate?

    func failAdd(with error: (any Error)?) { addError = error }
    /// `add` будет ждать, пока тест не откроет барьер.
    func holdAdd(at gate: Gate) { addGate = gate }
    func failUpdate(with error: (any Error)?) { updateError = error }
    func failDelete(with error: (any Error)?) { deleteError = error }
    /// `delete` будет ждать, пока тест не откроет барьер.
    func holdDelete(at gate: Gate) { deleteGate = gate }

    func add(_ vehicle: Vehicle) async throws {
        if let addGate { await addGate.arriveAndWait() }
        if let addError { throw addError }
        added.append(vehicle)
    }

    func update(_ vehicle: Vehicle) async throws {
        if let updateError { throw updateError }
        updated.append(vehicle)
    }

    func delete(id: Vehicle.ID) async throws {
        deleted.append(id)
        if let deleteGate { await deleteGate.arriveAndWait() }
        if let deleteError { throw deleteError }
    }
}

struct FakeReceiptPreparer: ReceiptImagePreparing {
    var transform: @Sendable (Data) async throws -> Data = { $0 }

    func prepare(_ data: Data) async throws -> Data { try await transform(data) }
}

final class FakeCredentials: SyncCredentialsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var url: URL?

    init(token: String? = nil, serverURL: URL? = nil) {
        self.token = token
        self.url = serverURL
    }

    func readToken() -> String? { lock.withLock { token } }
    func saveToken(_ token: String) throws { lock.withLock { self.token = token } }
    func deleteToken() throws { lock.withLock { token = nil } }
    func readServerURL() -> URL? { lock.withLock { url } }
    func saveServerURL(_ url: URL) { lock.withLock { self.url = url } }
    func deleteServerURL() { lock.withLock { url = nil } }
}

actor FakeRegistrar: DeviceRegistrar {
    private var gate: Gate?
    private var error: (any Error)?
    private(set) var callCount = 0

    func holdRequests(at gate: Gate) { self.gate = gate }
    func failWith(_ error: (any Error)?) { self.error = error }

    func register(serverURL: URL, setupSecret: String, deviceName: String) async throws -> String {
        callCount += 1
        if let gate { await gate.arriveAndWait() }
        if let error { throw error }
        return "token"
    }
}

/// Синхронизация, которая может «зависнуть» до отмены вызывающей задачи.
actor FakeSyncService: SyncService {
    private(set) var syncCount = 0
    private(set) var resetCount = 0
    private var summary = SyncSummary()
    private var error: (any Error)?
    private var hangs = false
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var status = SyncStatus()
    private var resetGate: Gate?

    /// Сброс будет ждать, пока тест не откроет барьер.
    func holdReset(at gate: Gate) { resetGate = gate }

    func succeed(with summary: SyncSummary) {
        self.summary = summary
        error = nil
        hangs = false
    }

    func fail(with error: any Error) { self.error = error }

    func hang() {
        hangs = true
        didStart = false
    }

    func setStatus(_ status: SyncStatus) { self.status = status }

    func waitUntilSyncStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }

    func sync() async throws -> SyncSummary {
        syncCount += 1
        didStart = true
        started?.resume()
        started = nil
        // Отмена прерывает сон исключением `CancellationError`.
        if hangs { try await Task.sleep(for: .seconds(3600)) }
        if let error { throw error }
        return summary
    }

    func status() async throws -> SyncStatus { status }

    func resetSyncState() async throws {
        if let resetGate { await resetGate.arriveAndWait() }
        resetCount += 1
        status = SyncStatus()
    }
}
