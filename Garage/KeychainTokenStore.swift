import Foundation
import Security

struct KeychainError: Error {
    var status: OSStatus
}

/// The device token of the sync server, kept as a generic password item.
struct KeychainTokenStore {
    private let service = "Garage.sync"
    private let account = "deviceToken"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        // Replace in place, so a failed write never loses the previous token.
        let update = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary)
        if update == errSecSuccess { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
