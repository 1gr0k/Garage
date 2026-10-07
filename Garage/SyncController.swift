import Foundation
import GarageAPI
import GarageStorage
import GarageSync
import Observation
import SwiftData
import UIKit

/// Registration and sync for the UI. The engine and the store do the work; this holds the state to show.
@Observable
final class SyncController {
    private(set) var isRegistered: Bool
    private(set) var isRegistering = false
    private(set) var isSyncing = false
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    private(set) var pendingCount = 0
    private(set) var receiptFailureCount = 0

    private let container: ModelContainer
    private let tokens = KeychainTokenStore()
    private let settings = SyncSettings()

    init(container: ModelContainer) {
        self.container = container
        isRegistered = tokens.read() != nil && settings.serverURL != nil
    }

    var serverURL: URL? { settings.serverURL }

    /// Reads the figures that outlive the process (last sync time, queue size).
    func refresh() async {
        let store = SwiftDataSyncStore(modelContainer: container)
        lastSyncAt = try? await store.lastSyncAt()
        pendingCount = (try? await store.pendingChangeCount()) ?? pendingCount
    }

    /// The secret is used for this one request and not kept.
    func register(serverURL text: String, secret: String) async -> Bool {
        guard !isRegistering else { return false }
        guard let url = SyncSettings.validate(text) else {
            lastError = String(localized: "Enter a valid server address. Use https, or http for localhost.")
            return false
        }
        isRegistering = true
        defer { isRegistering = false }
        do {
            let response = try await SyncAPIClient.registerDevice(
                transport: URLSessionHTTPTransport(baseURL: url), setupSecret: secret,
                deviceName: UIDevice.current.name)
            do {
                try tokens.save(response.token)
            } catch {
                lastError = String(localized: "Couldn't save the token to the Keychain.")
                return false
            }
            settings.serverURL = url
            isRegistered = true
            lastError = nil
            return true
        } catch {
            lastError = Self.message(for: error)
            return false
        }
    }

    func sync() async {
        guard isRegistered, !isSyncing else { return }
        guard let url = settings.serverURL, let token = tokens.read() else {
            isRegistered = false
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        let store = SwiftDataSyncStore(modelContainer: container)
        do {
            try SyncSupport.prepare(container)
            let engine = SyncEngine(
                store: store,
                client: SyncAPIClient(transport: URLSessionHTTPTransport(baseURL: url), token: token),
                receipts: store)
            let report = try await engine.sync()
            try await store.recordSyncFinished(at: .now)
            receiptFailureCount = report.receiptFailures.count
            lastError = nil
        } catch {
            lastError = Self.message(for: error)
        }
        await refresh()
    }

    func forgetDevice() {
        tokens.delete()
        try? SyncSupport.resetSyncState(container)
        lastSyncAt = nil
        isRegistered = false
        lastError = nil
        receiptFailureCount = 0
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case SyncError.api(_, let apiError) where apiError.code == .invalidSetupSecret:
            return String(localized: "The setup secret is wrong.")
        case SyncError.api(_, let apiError) where apiError.code == .unauthorized:
            return String(localized: "The server rejected this device. Forget it and register again.")
        case SyncError.api(_, let apiError) where apiError.code == .upgradeRequired:
            return String(localized: "Update the app to keep syncing.")
        case SyncError.api(let status, _), SyncError.http(let status):
            return String(localized: "The server returned an error (\(status)).")
        case SyncError.malformedResponse, is DecodingError:
            return String(localized: "The server sent an unexpected response.")
        case is URLError:
            return String(localized: "Can't reach the server.")
        default:
            return String(localized: "Synchronization failed.")
        }
    }
}
