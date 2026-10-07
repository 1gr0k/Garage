import Foundation

/// Правило для адреса сервера синхронизации.
public enum ServerURLPolicy {
    /// `https` для любого хоста; обычный `http` только для локальной машины (dev-сервер).
    public static func validate(_ text: String) -> URL? {
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

/// Регистрация устройства. Секрет настройки используется для одного запроса и нигде не хранится.
public struct RegisterDevice: Sendable {
    private let registrar: any DeviceRegistrar
    private let credentials: any SyncCredentialsStore

    public init(registrar: any DeviceRegistrar, credentials: any SyncCredentialsStore) {
        self.registrar = registrar
        self.credentials = credentials
    }

    /// - Throws: `SyncFailure` (или `CancellationError`).
    public func execute(serverURL text: String, setupSecret: String, deviceName: String) async throws {
        guard let url = ServerURLPolicy.validate(text) else { throw SyncFailure.invalidServerURL }
        let token: String
        do {
            token = try await registrar.register(serverURL: url, setupSecret: setupSecret, deviceName: deviceName)
        } catch let failure as SyncFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SyncFailure.other
        }
        do {
            try credentials.saveToken(token)
        } catch {
            throw SyncFailure.keychain
        }
        credentials.saveServerURL(url)
    }
}

/// Синхронизация сейчас; без токена или адреса сервера устройство считается незарегистрированным.
public struct SyncNow: Sendable {
    private let service: any SyncService
    private let credentials: any SyncCredentialsStore

    public init(service: any SyncService, credentials: any SyncCredentialsStore) {
        self.service = service
        self.credentials = credentials
    }

    /// - Throws: `SyncFailure` (или `CancellationError`).
    public func execute() async throws -> SyncSummary {
        guard credentials.readToken() != nil, credentials.readServerURL() != nil else {
            throw SyncFailure.notRegistered
        }
        do {
            return try await service.sync()
        } catch let failure as SyncFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SyncFailure.other
        }
    }
}

/// «Забыть устройство»: удаляет токен и сбрасывает состояние синхронизации. Адрес сервера остаётся.
public struct ForgetDevice: Sendable {
    private let service: any SyncService
    private let credentials: any SyncCredentialsStore

    public init(service: any SyncService, credentials: any SyncCredentialsStore) {
        self.service = service
        self.credentials = credentials
    }

    public func execute() async throws {
        // Сначала сброс: если он упадёт, устройство остаётся зарегистрированным и «Забыть» можно повторить.
        try await service.resetSyncState()
        credentials.deleteToken()
    }
}
