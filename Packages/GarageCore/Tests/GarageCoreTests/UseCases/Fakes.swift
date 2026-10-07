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

final class FakeCredentials: SyncCredentialsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var url: URL?
    var saveTokenError: (any Error)?
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
    func deleteToken() { lock.withLock { token = nil } }
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
    }
}

struct TestFailure: Error {}
