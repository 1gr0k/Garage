import Foundation
import Testing

@testable import GarageCore

// MARK: AddServiceRecord

@Test func addServiceRecordDoesNotReachRepositoryOnInvalidDraft() async {
    let repository = FakeRecordRepository()
    let useCase = AddServiceRecord(records: repository)

    await #expect(throws: ServiceRecordDraft.Errors.self) {
        try await useCase.execute(draft: ServiceRecordDraft(mileageText: ""), vehicleID: UUID(), receipt: nil)
    }
    #expect(repository.added.isEmpty)
}

@Test func addServiceRecordPassesRecordAndReceipt() async throws {
    let repository = FakeRecordRepository()
    let vehicleID = UUID()
    let receipt = Data([1, 2, 3])

    try await AddServiceRecord(records: repository).execute(
        draft: ServiceRecordDraft(mileageText: "1000"), vehicleID: vehicleID, receipt: receipt)

    #expect(repository.added.count == 1)
    #expect(repository.added[0].record.vehicleID == vehicleID)
    #expect(repository.added[0].record.mileageKm == 1000)
    #expect(repository.added[0].receipt == receipt)
}

@Test func addServiceRecordPropagatesRepositoryError() async {
    let repository = FakeRecordRepository()
    let vehicleID = UUID()
    repository.error = RepositoryError.vehicleNotFound(vehicleID)

    await #expect(throws: RepositoryError.vehicleNotFound(vehicleID)) {
        try await AddServiceRecord(records: repository).execute(
            draft: ServiceRecordDraft(mileageText: "1000"), vehicleID: vehicleID, receipt: nil)
    }
}

// MARK: UpdateServiceRecord

private func makeOriginal() throws -> ServiceRecord {
    try ServiceRecord(
        vehicleID: UUID(), date: Date(timeIntervalSince1970: 1_700_000_000), mileageKm: 1000,
        serviceType: .oilChange, laborCost: Money(rubles: 500))
}

@Test func updateServiceRecordDoesNotReachRepositoryOnInvalidDraft() async throws {
    let editor = FakeRecordEditor()
    let original = try makeOriginal()

    await #expect(throws: ServiceRecordDraft.Errors.self) {
        try await UpdateServiceRecord(records: editor).execute(
            draft: ServiceRecordDraft(mileageText: ""), original: original, receipt: .keep)
    }
    #expect(editor.updated.isEmpty)
}

@Test func updateServiceRecordKeepsIdentityAndPassesReceiptChange() async throws {
    let editor = FakeRecordEditor()
    let original = try makeOriginal()
    var draft = ServiceRecordDraft(record: original)
    draft.mileageText = "2000"
    let receipt = ReceiptChange.replace(Data([1, 2, 3]))

    try await UpdateServiceRecord(records: editor).execute(draft: draft, original: original, receipt: receipt)

    #expect(editor.updated.count == 1)
    #expect(editor.updated[0].record.id == original.id)
    #expect(editor.updated[0].record.vehicleID == original.vehicleID)
    #expect(editor.updated[0].record.mileageKm == 2000)
    #expect(editor.updated[0].receipt == receipt)
}

@Test func updateServiceRecordSkipsRepositoryWhenNothingChanged() async throws {
    let editor = FakeRecordEditor()
    let original = try makeOriginal()

    try await UpdateServiceRecord(records: editor).execute(
        draft: ServiceRecordDraft(record: original), original: original, receipt: .keep)

    #expect(editor.updated.isEmpty)
}

@Test(arguments: [ReceiptChange.remove, .replace(Data([9]))])
func updateServiceRecordCallsRepositoryWhenOnlyReceiptChanged(receipt: ReceiptChange) async throws {
    let editor = FakeRecordEditor()
    let original = try makeOriginal()

    try await UpdateServiceRecord(records: editor).execute(
        draft: ServiceRecordDraft(record: original), original: original, receipt: receipt)

    #expect(editor.updated.count == 1)
    #expect(editor.updated[0].receipt == receipt)
}

@Test func updateServiceRecordPropagatesRecordNotFound() async throws {
    let editor = FakeRecordEditor()
    let original = try makeOriginal()
    editor.error = RepositoryError.recordNotFound(original.id)
    var draft = ServiceRecordDraft(record: original)
    draft.notes = "changed"

    await #expect(throws: RepositoryError.recordNotFound(original.id)) {
        try await UpdateServiceRecord(records: editor).execute(draft: draft, original: original, receipt: .keep)
    }
}

// MARK: RegisterDevice

private let secret = "s3cret-value"

private func register(
    _ url: String, registrar: FakeRegistrar = FakeRegistrar(), credentials: FakeCredentials = FakeCredentials()
) async throws {
    try await RegisterDevice(registrar: registrar, credentials: credentials)
        .execute(serverURL: url, setupSecret: secret, deviceName: "iPhone")
}

@Test(arguments: ["http://example.com", "ftp://example.com", "example.com", "", "https://user:pw@example.com"])
func registerRejectsInvalidServerURL(text: String) async {
    let credentials = FakeCredentials()

    await #expect(throws: SyncFailure.invalidServerURL) { try await register(text, credentials: credentials) }
    #expect(credentials.readToken() == nil)
}

@Test(arguments: ["https://example.com", "http://localhost:8080", "http://127.0.0.1:8080"])
func registerAcceptsAllowedURLsAndStoresCredentials(text: String) async throws {
    let credentials = FakeCredentials()

    try await register(text, credentials: credentials)

    #expect(credentials.readToken() == "token-1")
    #expect(credentials.readServerURL() != nil)
}

@Test func registerNeverStoresSetupSecret() async throws {
    let credentials = FakeCredentials()

    try await register("https://example.com", credentials: credentials)

    #expect(!credentials.written.contains(secret))
}

@Test func registerMapsKeychainErrorToFailure() async {
    let credentials = FakeCredentials()
    credentials.saveTokenError = TestFailure()

    await #expect(throws: SyncFailure.keychain) { try await register("https://example.com", credentials: credentials) }
    #expect(credentials.readServerURL() == nil)
}

@Test func registerPassesRegistrarFailureThrough() async {
    let registrar = FakeRegistrar()
    registrar.error = SyncFailure.invalidSetupSecret
    let credentials = FakeCredentials()

    await #expect(throws: SyncFailure.invalidSetupSecret) {
        try await register("https://example.com", registrar: registrar, credentials: credentials)
    }
    #expect(credentials.readToken() == nil)
}

@Test func registerWrapsUnknownRegistrarErrorAsOther() async {
    let registrar = FakeRegistrar()
    registrar.error = TestFailure()

    await #expect(throws: SyncFailure.other) { try await register("https://example.com", registrar: registrar) }
}

// MARK: SyncNow

@Test func syncNowWithoutRegistrationFailsAndDoesNotSync() async {
    let service = FakeSyncService()

    await #expect(throws: SyncFailure.notRegistered) {
        try await SyncNow(service: service, credentials: FakeCredentials()).execute()
    }
    // Токен есть, адреса нет — тоже не зарегистрирован.
    await #expect(throws: SyncFailure.notRegistered) {
        try await SyncNow(service: service, credentials: FakeCredentials(token: "t")).execute()
    }
    #expect(service.syncCount == 0)
}

@Test func syncNowReturnsSummary() async throws {
    let service = FakeSyncService()
    service.summary = SyncSummary(receiptFailureCount: 1, stillPendingCount: 2)
    let credentials = FakeCredentials(token: "t", serverURL: URL(string: "https://example.com"))

    let summary = try await SyncNow(service: service, credentials: credentials).execute()

    #expect(summary == SyncSummary(receiptFailureCount: 1, stillPendingCount: 2))
}

@Test func syncNowKeepsCancellationAndFailures() async {
    let service = FakeSyncService()
    let credentials = FakeCredentials(token: "t", serverURL: URL(string: "https://example.com"))
    let useCase = SyncNow(service: service, credentials: credentials)

    service.error = CancellationError()
    await #expect(throws: CancellationError.self) { try await useCase.execute() }
    service.error = SyncFailure.network
    await #expect(throws: SyncFailure.network) { try await useCase.execute() }
    service.error = TestFailure()
    await #expect(throws: SyncFailure.other) { try await useCase.execute() }
}

// MARK: ForgetDevice

@Test func forgetDeviceDeletesTokenAndResetsStateButKeepsServerURL() async throws {
    let service = FakeSyncService()
    let url = URL(string: "https://example.com")
    let credentials = FakeCredentials(token: "t", serverURL: url)

    try await ForgetDevice(service: service, credentials: credentials).execute()

    #expect(credentials.readToken() == nil)
    #expect(credentials.readServerURL() == url)
    #expect(service.resetCount == 1)
}

@Test func forgetDeviceKeepsTokenWhenResetFails() async throws {
    let service = FakeSyncService()
    service.resetError = TestFailure()
    let credentials = FakeCredentials(token: "t", serverURL: URL(string: "https://example.com"))

    await #expect(throws: TestFailure.self) {
        try await ForgetDevice(service: service, credentials: credentials).execute()
    }

    #expect(credentials.readToken() == "t")
}

@Test func forgetDeviceMapsTokenDeletionErrorToKeychain() async {
    let credentials = FakeCredentials(token: "t", serverURL: URL(string: "https://example.com"))
    credentials.deleteTokenError = TestFailure()

    await #expect(throws: SyncFailure.keychain) {
        try await ForgetDevice(service: FakeSyncService(), credentials: credentials).execute()
    }
}
