import Foundation
import GarageCore
import Observation

/// Регистрация и синхронизация для UI: use case'ы делают работу, здесь только состояние для показа.
@Observable
final class SyncViewModel {
    private(set) var isRegistered: Bool
    private(set) var isRegistering = false
    private(set) var isSyncing = false
    /// Пока идёт «Забыть устройство», новая синхронизация не запускается: она записала бы курсор поверх сброса.
    private(set) var isForgetting = false
    private(set) var lastSyncAt: Date?
    private(set) var lastFailure: SyncFailure?
    private(set) var pendingCount = 0
    private(set) var receiptFailureCount = 0

    private let service: any SyncService
    private let registerDevice: RegisterDevice
    private let syncNow: SyncNow
    private let forgetDeviceUseCase: ForgetDevice
    private let credentials: any SyncCredentialsStore
    private let deviceName: @MainActor () -> String

    private var syncTask: Task<Void, Never>?
    /// Растёт при «Забыть устройство»: результаты синхронизации, начатой до этого, больше ничего не меняют.
    private var generation = 0

    init(
        service: any SyncService, registerDevice: RegisterDevice, syncNow: SyncNow, forgetDevice: ForgetDevice,
        credentials: any SyncCredentialsStore, deviceName: @escaping @MainActor () -> String
    ) {
        self.service = service
        self.registerDevice = registerDevice
        self.syncNow = syncNow
        self.forgetDeviceUseCase = forgetDevice
        self.credentials = credentials
        self.deviceName = deviceName
        isRegistered = credentials.isRegistered
    }

    var serverURL: URL? { credentials.readServerURL() }

    var lastError: String? { lastFailure?.message }

    /// Читает то, что переживает процесс: время последней синхронизации и размер очереди.
    func refresh() async {
        let generation = generation
        let status = try? await service.status()
        guard generation == self.generation, let status else { return }
        lastSyncAt = status.lastSyncAt
        pendingCount = status.pendingCount
    }

    /// Секрет используется для одного запроса и не сохраняется.
    func register(serverURL text: String, secret: String) async -> Bool {
        guard !isRegistering else { return false }
        isRegistering = true
        defer { isRegistering = false }
        do {
            try await registerDevice.execute(serverURL: text, setupSecret: secret, deviceName: deviceName())
            isRegistered = true
            lastFailure = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            lastFailure = Self.failure(from: error)
            return false
        }
    }

    /// Запускает синхронизацию в задаче, которой владеет модель: «Забыть устройство» может её отменить.
    func startSync() {
        guard isRegistered, !isForgetting, syncTask == nil else { return }
        isSyncing = true
        let generation = generation
        syncTask = Task { await performSync(generation: generation) }
    }

    /// Запускает синхронизацию и ждёт её окончания.
    func sync() async {
        startSync()
        await syncTask?.value
    }

    /// Останавливает идущую синхронизацию, затем сбрасывает состояние; адрес сервера остаётся.
    func forgetDevice() async {
        guard !isForgetting else { return }
        isForgetting = true
        defer { isForgetting = false }
        generation += 1
        let running = syncTask
        running?.cancel()
        await running?.value
        syncTask = nil
        isSyncing = false
        do {
            try await forgetDeviceUseCase.execute()
        } catch {
            lastFailure = Self.failure(from: error)
            return
        }
        isRegistered = false
        lastFailure = nil
        receiptFailureCount = 0
        lastSyncAt = nil
        await refresh()
    }

    private func performSync(generation: Int) async {
        defer {
            if generation == self.generation {
                isSyncing = false
                syncTask = nil
            }
        }
        do {
            let summary = try await syncNow.execute()
            guard generation == self.generation else { return }
            receiptFailureCount = summary.receiptFailureCount
            lastFailure = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            let failure = Self.failure(from: error)
            if failure == .notRegistered {
                isRegistered = false
                lastFailure = nil
                return
            }
            lastFailure = failure
        }
        await refresh()
    }

    private static func failure(from error: any Error) -> SyncFailure {
        (error as? SyncFailure) ?? .other
    }
}
