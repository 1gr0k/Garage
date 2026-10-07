import Foundation

/// Итог одного запуска синхронизации.
public struct SyncSummary: Hashable, Sendable {
    public var receiptFailureCount: Int
    public var stillPendingCount: Int

    public init(receiptFailureCount: Int = 0, stillPendingCount: Int = 0) {
        self.receiptFailureCount = receiptFailureCount
        self.stillPendingCount = stillPendingCount
    }
}

/// Состояние синхронизации, которое переживает процесс.
public struct SyncStatus: Hashable, Sendable {
    public var lastSyncAt: Date?
    public var pendingCount: Int

    public init(lastSyncAt: Date? = nil, pendingCount: Int = 0) {
        self.lastSyncAt = lastSyncAt
        self.pendingCount = pendingCount
    }
}

/// Причина сбоя регистрации или синхронизации. По ней ViewModel строит сообщение, не зная о GarageSync.
public enum SyncFailure: Error, Hashable, Sendable {
    case notRegistered
    case invalidSetupSecret
    case unauthorized
    case upgradeRequired
    case server(status: Int)
    case malformedResponse
    case network
    case keychain
    case invalidServerURL
    case other
}

public protocol SyncService: Sendable {
    /// Один полный цикл push → pull. Отмена вызывающей задачи прерывает синхронизацию (`CancellationError`).
    func sync() async throws -> SyncSummary
    func status() async throws -> SyncStatus
    /// Сбрасывает курсор и запомненные версии (после «Забыть устройство»).
    func resetSyncState() async throws
}

public protocol DeviceRegistrar: Sendable {
    /// Регистрирует устройство и возвращает токен. Бросает `SyncFailure`.
    func register(serverURL: URL, setupSecret: String, deviceName: String) async throws -> String
}

/// Токен и адрес сервера. Синхронный: за ним Keychain и UserDefaults.
public protocol SyncCredentialsStore: Sendable {
    func readToken() -> String?
    func saveToken(_ token: String) throws
    /// Отсутствие токена — не ошибка.
    func deleteToken() throws
    func readServerURL() -> URL?
    func saveServerURL(_ url: URL)
    func deleteServerURL()
}

extension SyncCredentialsStore {
    /// Устройство зарегистрировано: есть и токен, и адрес сервера.
    public var isRegistered: Bool { readToken() != nil && readServerURL() != nil }
}
