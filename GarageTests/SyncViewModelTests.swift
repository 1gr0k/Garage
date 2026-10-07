import Foundation
import GarageCore
import Testing

@testable import Garage

@MainActor
struct SyncViewModelTests {
    private let url = URL(string: "https://example.com")!

    private func makeModel(
        service: FakeSyncService = FakeSyncService(), registrar: FakeRegistrar = FakeRegistrar(),
        credentials: FakeCredentials
    ) -> SyncViewModel {
        SyncViewModel(
            service: service,
            registerDevice: RegisterDevice(registrar: registrar, credentials: credentials),
            syncNow: SyncNow(service: service, credentials: credentials),
            forgetDevice: ForgetDevice(service: service, credentials: credentials),
            credentials: credentials, deviceName: { "Test iPhone" })
    }

    private func registeredCredentials() -> FakeCredentials {
        FakeCredentials(token: "t", serverURL: url)
    }

    // MARK: Регистрация

    @Test func startsUnregisteredWithoutCredentials() {
        let model = makeModel(credentials: FakeCredentials())

        #expect(!model.isRegistered)
    }

    @Test func registerSucceedsAndStoresCredentials() async {
        let credentials = FakeCredentials()
        let model = makeModel(credentials: credentials)

        let ok = await model.register(serverURL: "https://example.com", secret: "s")

        #expect(ok)
        #expect(model.isRegistered)
        #expect(model.lastFailure == nil)
        #expect(credentials.readToken() == "token")
    }

    @Test func registerFailureShowsMessage() async {
        let registrar = FakeRegistrar()
        await registrar.failWith(SyncFailure.invalidSetupSecret)
        let model = makeModel(registrar: registrar, credentials: FakeCredentials())

        let ok = await model.register(serverURL: "https://example.com", secret: "bad")

        #expect(!ok)
        #expect(!model.isRegistered)
        #expect(model.lastFailure == .invalidSetupSecret)
        #expect(model.lastError == SyncFailure.invalidSetupSecret.message)
    }

    @Test func invalidServerURLIsRejectedWithoutRequest() async {
        let registrar = FakeRegistrar()
        let model = makeModel(registrar: registrar, credentials: FakeCredentials())

        let ok = await model.register(serverURL: "http://example.com", secret: "s")

        #expect(!ok)
        #expect(model.lastFailure == .invalidServerURL)
        #expect(await registrar.callCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func secondRegistrationDuringFirstIsIgnored() async {
        let registrar = FakeRegistrar()
        let gate = Gate()
        await registrar.holdRequests(at: gate)
        let model = makeModel(registrar: registrar, credentials: FakeCredentials())

        let first = Task { await model.register(serverURL: "https://example.com", secret: "s") }
        await gate.waitForArrival()
        #expect(model.isRegistering)
        let second = await model.register(serverURL: "https://example.com", secret: "s")
        await gate.open()

        #expect(!second)
        #expect(await first.value)
        #expect(await registrar.callCount == 1)
        #expect(!model.isRegistering)
    }

    // MARK: Синхронизация

    @Test func syncSuccessUpdatesState() async {
        let service = FakeSyncService()
        await service.succeed(with: SyncSummary(receiptFailureCount: 2, stillPendingCount: 0))
        await service.setStatus(SyncStatus(lastSyncAt: Date(timeIntervalSince1970: 100), pendingCount: 3))
        let model = makeModel(service: service, credentials: registeredCredentials())

        await model.sync()

        #expect(!model.isSyncing)
        #expect(model.lastFailure == nil)
        #expect(model.receiptFailureCount == 2)
        #expect(model.lastSyncAt == Date(timeIntervalSince1970: 100))
        #expect(model.pendingCount == 3)
    }

    @Test func syncFailureShowsMessage() async {
        let service = FakeSyncService()
        await service.fail(with: SyncFailure.network)
        let model = makeModel(service: service, credentials: registeredCredentials())

        await model.sync()

        #expect(model.lastFailure == .network)
        #expect(!model.isSyncing)
    }

    @Test func syncWithoutRegistrationDoesNothing() async {
        let service = FakeSyncService()
        let model = makeModel(service: service, credentials: FakeCredentials())

        await model.sync()

        #expect(await service.syncCount == 0)
        #expect(!model.isSyncing)
    }

    @Test(.timeLimit(.minutes(1)))
    func forgetDuringSyncCancelsItAndLeavesNoErrorOrOldCounters() async {
        let service = FakeSyncService()
        let credentials = registeredCredentials()
        let model = makeModel(service: service, credentials: credentials)
        await service.succeed(with: SyncSummary(receiptFailureCount: 2, stillPendingCount: 0))
        await model.sync()
        #expect(model.receiptFailureCount == 2)

        await service.hang()
        model.startSync()
        await service.waitUntilSyncStarted()
        #expect(model.isSyncing)
        await model.forgetDevice()

        #expect(!model.isSyncing)
        #expect(!model.isRegistered)
        #expect(model.lastFailure == nil)
        #expect(model.receiptFailureCount == 0)
        #expect(model.lastSyncAt == nil)
        #expect(credentials.readToken() == nil)
        #expect(credentials.readServerURL() == url)
        #expect(await service.resetCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelledSyncIsNotShownAsError() async {
        let service = FakeSyncService()
        await service.hang()
        let model = makeModel(service: service, credentials: registeredCredentials())

        model.startSync()
        await service.waitUntilSyncStarted()
        await model.forgetDevice()

        #expect(model.lastFailure == nil)
    }

    @Test func forgetFailureKeepsDeviceRegistered() async {
        let service = FailingResetService()
        let credentials = registeredCredentials()
        let model = SyncViewModel(
            service: service,
            registerDevice: RegisterDevice(registrar: FakeRegistrar(), credentials: credentials),
            syncNow: SyncNow(service: service, credentials: credentials),
            forgetDevice: ForgetDevice(service: service, credentials: credentials),
            credentials: credentials, deviceName: { "Test iPhone" })

        await model.forgetDevice()

        #expect(model.isRegistered)
        #expect(model.lastFailure == .other)
        #expect(credentials.readToken() == "t")
    }
}

private struct FailingResetService: SyncService {
    func sync() async throws -> SyncSummary { SyncSummary() }
    func status() async throws -> SyncStatus { SyncStatus() }
    func resetSyncState() async throws { throw TestFailure() }
}
