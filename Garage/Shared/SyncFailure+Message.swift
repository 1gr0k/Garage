import Foundation
import GarageCore

extension SyncFailure {
    /// Текст для пользователя. Ключи каталога те же, что были у `SyncController`.
    var message: String {
        switch self {
        case .invalidServerURL:
            String(localized: "Enter a valid server address. Use https, or http for localhost.")
        case .keychain:
            String(localized: "Couldn't save the token to the Keychain.")
        case .invalidSetupSecret:
            String(localized: "The setup secret is wrong.")
        case .unauthorized:
            String(localized: "The server rejected this device. Forget it and register again.")
        case .upgradeRequired:
            String(localized: "Update the app to keep syncing.")
        case .server(let status):
            String(localized: "The server returned an error (\(status)).")
        case .malformedResponse:
            String(localized: "The server sent an unexpected response.")
        case .network:
            String(localized: "Can't reach the server.")
        case .notRegistered, .other:
            String(localized: "Synchronization failed.")
        }
    }
}
