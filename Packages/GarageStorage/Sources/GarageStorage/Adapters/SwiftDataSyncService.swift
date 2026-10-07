import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData

/// `SyncService` на SwiftData: готовит хранилище, гоняет `SyncEngine` и запоминает время успешной синхронизации.
/// Токен и адрес сервера читает из `SyncCredentialsStore` при каждом запуске.
public actor SwiftDataSyncService: SyncService {
    private let container: ModelContainer
    private let credentials: any SyncCredentialsStore
    private let makeTransport: @Sendable (URL) -> any HTTPTransport

    public init(
        container: ModelContainer,
        credentials: any SyncCredentialsStore,
        makeTransport: @escaping @Sendable (URL) -> any HTTPTransport = { URLSessionHTTPTransport(baseURL: $0) }
    ) {
        self.container = container
        self.credentials = credentials
        self.makeTransport = makeTransport
    }

    public func sync() async throws -> SyncSummary {
        guard let token = credentials.readToken(), let url = credentials.readServerURL() else {
            throw SyncFailure.notRegistered
        }
        do {
            try SyncSupport.prepare(container)
            let store = SwiftDataSyncStore(modelContainer: container)
            let engine = SyncEngine(
                store: store, client: SyncAPIClient(transport: makeTransport(url), token: token), receipts: store)
            let report = try await engine.sync()
            try Task.checkCancellation()
            try await store.recordSyncFinished(at: .now)
            return SyncSummary(
                receiptFailureCount: report.receiptFailures.count, stillPendingCount: report.stillPending.count)
        } catch {
            // Отмена на уровне URLSession приходит как `URLError.cancelled`.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SyncFailure(error)
        }
    }

    public func status() async throws -> SyncStatus {
        let store = SwiftDataSyncStore(modelContainer: container)
        return SyncStatus(
            lastSyncAt: try await store.lastSyncAt(), pendingCount: try await store.pendingChangeCount())
    }

    public func resetSyncState() async throws {
        try SyncSupport.resetSyncState(container)
    }
}
