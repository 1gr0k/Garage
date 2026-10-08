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
    private let logNotice: @Sendable (String) -> Void

    /// - Parameter logNotice: куда пишутся замечания о терпимом чтении контракта (не ошибки); по умолчанию — лог
    ///   `Sync`. Только имена видов/значений и ключи сущностей, без данных пользователя.
    public init(
        container: ModelContainer,
        credentials: any SyncCredentialsStore,
        makeTransport: @escaping @Sendable (URL) -> any HTTPTransport = { URLSessionHTTPTransport(baseURL: $0) },
        logNotice: (@Sendable (String) -> Void)? = nil
    ) {
        self.container = container
        self.credentials = credentials
        self.makeTransport = makeTransport
        self.logNotice = logNotice ?? { syncLogger.notice("\($0, privacy: .public)") }
    }

    /// Общий прогон: актор реентерабелен, поэтому без него два параллельных `sync()` запушили бы один батч дважды.
    private var inFlight: Task<SyncSummary, any Error>?

    /// Параллельные вызовы делят один прогон; отмена любого из них отменяет его целиком (как в `SyncEngine`).
    public func sync() async throws -> SyncSummary {
        if let running = inFlight {
            return try await withTaskCancellationHandler {
                try await running.value
            } onCancel: {
                running.cancel()
            }
        }
        let task = Task { try await self.performSync() }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performSync() async throws -> SyncSummary {
        guard let token = credentials.readToken(), let url = credentials.readServerURL() else {
            throw SyncFailure.notRegistered
        }
        do {
            try SyncSupport.prepare(container)
            let store = SwiftDataSyncStore(modelContainer: container)
            let engine = SyncEngine(
                store: store, client: SyncAPIClient(transport: makeTransport(url), token: token), receipts: store)
            let report = try await engine.sync()
            logTolerance(of: report)
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

    /// Пишет в лог **при каждом прогоне**, где было пропущено или оставлено в очереди незнакомое (R12): застрявшая
    /// правка находится по повторяющейся строке.
    private func logTolerance(of report: SyncReport) {
        if !report.skippedUnrecognized.isEmpty {
            logNotice("Skipped unrecognized server changes: \(report.skippedUnrecognized.joined(separator: ", "))")
        }
        // Одна запись на пару (статус, сущность) с числом повторов в этом прогоне.
        var counts: [String: Int] = [:]
        for outcome in report.unrecognizedOutcomes {
            counts["\(outcome.status) \(SyncState.refKey(outcome.ref))", default: 0] += 1
        }
        for (key, count) in counts.sorted(by: { $0.key < $1.key }) {
            logNotice("Unrecognized push outcome, change stays queued: \(key), times in this run: \(count)")
        }
    }

    public func status() async throws -> SyncStatus {
        let store = SwiftDataSyncStore(modelContainer: container)
        return SyncStatus(
            lastSyncAt: try await store.lastSyncAt(), pendingCount: try await store.pendingChangeCount())
    }

    public func resetSyncState() async throws {
        // Идущий прогон записал бы курсор и версии поверх сброса: сначала отменяем и дожидаемся его.
        // Цикл: прогон, начатый, пока мы ждали предыдущий, тоже должен закончиться до сброса.
        // Уже дождавшийся прогон может ещё висеть в `inFlight` (его `defer` не успел выполниться) — не ждём его снова.
        var finished: Task<SyncSummary, any Error>?
        while let running = inFlight, running != finished {
            running.cancel()
            _ = try? await running.value
            finished = running
        }
        try SyncSupport.resetSyncState(container)
    }
}
