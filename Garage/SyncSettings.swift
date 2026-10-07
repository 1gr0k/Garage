import Foundation

/// The server address. The setup secret is deliberately not stored anywhere, and the token lives in the Keychain.
struct SyncSettings {
    private static let serverURLKey = "Garage.sync.serverURL"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var serverURL: URL? {
        get { defaults.string(forKey: Self.serverURLKey).flatMap(URL.init(string:)) }
        nonmutating set { defaults.set(newValue?.absoluteString, forKey: Self.serverURLKey) }
    }

    /// `https` anywhere; plain `http` only for the local machine (the dev server).
    static func validate(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let host = components.host?.lowercased(),
            !host.isEmpty, components.user == nil, components.password == nil
        else { return nil }
        switch components.scheme?.lowercased() {
        case "https": break
        case "http" where host == "localhost" || host == "127.0.0.1": break
        default: return nil
        }
        return components.url
    }
}
