import Foundation

@testable import GarageCore

/// Фейки протоколов GarageCore: записывают вызовы, ошибки задаются заранее.
final class FakeRecordRepository: ServiceRecordRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var _added: [(record: ServiceRecord, receipt: Data?)] = []
    var error: (any Error)?

    var added: [(record: ServiceRecord, receipt: Data?)] { lock.withLock { _added } }

    func add(_ record: ServiceRecord, receiptImage: Data?) async throws {
        if let error { throw error }
        lock.withLock { _added.append((record, receiptImage)) }
    }
}

final class FakeRecordEditor: ServiceRecordEditing, @unchecked Sendable {
    private let lock = NSLock()
    private var _updated: [(record: ServiceRecord, receipt: ReceiptChange)] = []
    private var _deleted: [UUID] = []
    var error: (any Error)?

    var updated: [(record: ServiceRecord, receipt: ReceiptChange)] { lock.withLock { _updated } }
    var deleted: [UUID] { lock.withLock { _deleted } }

    func update(_ record: ServiceRecord, receipt: ReceiptChange) async throws {
        if let error { throw error }
        lock.withLock { _updated.append((record, receipt)) }
    }

    func delete(id: ServiceRecord.ID) async throws {
        if let error { throw error }
        lock.withLock { _deleted.append(id) }
    }
}

final class FakeVehicleRepository: VehicleRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var _added: [Vehicle] = []
    private var _updated: [Vehicle] = []
    private var _deleted: [UUID] = []
    var error: (any Error)?

    var added: [Vehicle] { lock.withLock { _added } }
    var updated: [Vehicle] { lock.withLock { _updated } }
    var deleted: [UUID] { lock.withLock { _deleted } }

    func add(_ vehicle: Vehicle) async throws {
        if let error { throw error }
        lock.withLock { _added.append(vehicle) }
    }

    func update(_ vehicle: Vehicle) async throws {
        if let error { throw error }
        lock.withLock { _updated.append(vehicle) }
    }

    func delete(id: Vehicle.ID) async throws {
        if let error { throw error }
        lock.withLock { _deleted.append(id) }
    }
}

final class FakeCredentials: SyncCredentialsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var url: URL?
    var saveTokenError: (any Error)?
    var deleteTokenError: (any Error)?
    /// Всё, что было записано как токен или адрес; нужно, чтобы проверить, что секрет не сохраняется.
    private var _written: [String] = []

    var written: [String] { lock.withLock { _written } }

    init(token: String? = nil, serverURL: URL? = nil) {
        self.token = token
        self.url = serverURL
    }

    func readToken() -> String? { lock.withLock { token } }
    func saveToken(_ token: String) throws {
        if let saveTokenError { throw saveTokenError }
        lock.withLock {
            self.token = token
            _written.append(token)
        }
    }
    func deleteToken() throws {
        if let deleteTokenError { throw deleteTokenError }
        lock.withLock { token = nil }
    }
    func readServerURL() -> URL? { lock.withLock { url } }
    func saveServerURL(_ url: URL) {
        lock.withLock {
            self.url = url
            _written.append(url.absoluteString)
        }
    }
    func deleteServerURL() { lock.withLock { url = nil } }
}

final class FakeRegistrar: DeviceRegistrar, @unchecked Sendable {
    var token = "token-1"
    var error: (any Error)?

    func register(serverURL: URL, setupSecret: String, deviceName: String) async throws -> String {
        if let error { throw error }
        return token
    }
}

final class FakeSyncService: SyncService, @unchecked Sendable {
    private let lock = NSLock()
    private var _syncCount = 0
    private var _resetCount = 0
    var summary = SyncSummary()
    var error: (any Error)?
    var resetError: (any Error)?

    var syncCount: Int { lock.withLock { _syncCount } }
    var resetCount: Int { lock.withLock { _resetCount } }

    func sync() async throws -> SyncSummary {
        lock.withLock { _syncCount += 1 }
        if let error { throw error }
        return summary
    }

    func status() async throws -> SyncStatus { SyncStatus() }

    func resetSyncState() async throws {
        lock.withLock { _resetCount += 1 }
        if let resetError { throw resetError }
    }
}

final class FakeRuleRepository: MaintenanceRuleRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var _added: [MaintenanceRule] = []
    private var _updated: [MaintenanceRule] = []
    private var _deleted: [UUID] = []
    var error: (any Error)?

    var added: [MaintenanceRule] { lock.withLock { _added } }
    var updated: [MaintenanceRule] { lock.withLock { _updated } }
    var deleted: [UUID] { lock.withLock { _deleted } }

    func add(_ rule: MaintenanceRule) async throws {
        if let error { throw error }
        lock.withLock { _added.append(rule) }
    }

    func update(_ rule: MaintenanceRule) async throws {
        if let error { throw error }
        lock.withLock { _updated.append(rule) }
    }

    func delete(id: MaintenanceRule.ID) async throws {
        if let error { throw error }
        lock.withLock { _deleted.append(id) }
    }
}

final class FakeSnapshotReader: MaintenanceSnapshotReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _readCount = 0
    var data = MaintenanceSnapshot()
    var error: (any Error)?

    var readCount: Int { lock.withLock { _readCount } }

    func snapshot() async throws -> MaintenanceSnapshot {
        lock.withLock { _readCount += 1 }
        if let error { throw error }
        return data
    }
}

final class FakeReminderScheduler: ReminderScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _replaced: [[ScheduledReminder]] = []
    private var _requestCount = 0
    private var _status: ReminderAuthorization
    let statusAfterRequest: ReminderAuthorization
    var error: (any Error)?

    init(status: ReminderAuthorization = .authorized, statusAfterRequest: ReminderAuthorization = .authorized) {
        _status = status
        self.statusAfterRequest = statusAfterRequest
    }

    var status: ReminderAuthorization { lock.withLock { _status } }
    var replaced: [[ScheduledReminder]] { lock.withLock { _replaced } }
    var requestCount: Int { lock.withLock { _requestCount } }

    func authorization() async -> ReminderAuthorization { status }

    func requestAuthorization() async -> ReminderAuthorization {
        lock.withLock {
            _requestCount += 1
            if _status == .notDetermined { _status = statusAfterRequest }
            return _status
        }
    }

    func replaceAll(with reminders: [ScheduledReminder]) async throws {
        if let error { throw error }
        lock.withLock { _replaced.append(reminders) }
    }
}

struct TestFailure: Error {}
