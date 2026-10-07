import Foundation
import GarageCore
import Security

struct KeychainError: Error {
    var status: OSStatus
}

/// Токен устройства лежит в Keychain (generic password), адрес сервера — в `UserDefaults`.
/// Секрет настройки сознательно нигде не хранится.
nonisolated struct KeychainCredentialsStore: SyncCredentialsStore {
    private static let serverURLKey = "Garage.sync.serverURL"
    private let service = "Garage.sync"
    private let account = "deviceToken"
    /// `UserDefaults` потокобезопасен, но не помечен `Sendable`.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func readToken() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveToken(_ token: String) throws {
        // Заменяем на месте, чтобы неудачная запись не потеряла прежний токен.
        let update = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary)
        if update == errSecSuccess { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func deleteToken() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func readServerURL() -> URL? {
        defaults.string(forKey: Self.serverURLKey).flatMap(URL.init(string:))
    }

    func saveServerURL(_ url: URL) {
        defaults.set(url.absoluteString, forKey: Self.serverURLKey)
    }

    func deleteServerURL() {
        defaults.removeObject(forKey: Self.serverURLKey)
    }
}
