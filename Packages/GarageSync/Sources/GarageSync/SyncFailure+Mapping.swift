import Foundation
import GarageAPI
import GarageCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension SyncError {
    /// Единственное место, где ошибка клиента превращается в доменную причину сбоя.
    public func toFailure() -> SyncFailure {
        switch self {
        case .api(_, let apiError) where apiError.code == .invalidSetupSecret: return .invalidSetupSecret
        case .api(_, let apiError) where apiError.code == .unauthorized: return .unauthorized
        case .api(_, let apiError) where apiError.code == .upgradeRequired: return .upgradeRequired
        case .api(let status, _), .http(let status): return .server(status: status)
        case .malformedResponse: return .malformedResponse
        }
    }
}

extension SyncFailure {
    /// Любая ошибка синхронизации → причина сбоя. `CancellationError` сюда передавать не нужно:
    /// вызывающий пробрасывает её как есть.
    public init(_ error: any Error) {
        switch error {
        case let failure as SyncFailure: self = failure
        case let error as SyncError: self = error.toFailure()
        case is DecodingError: self = .malformedResponse
        case is URLError: self = .network
        default: self = .other
        }
    }
}

/// Регистрация устройства через `POST /v1/devices`.
public struct SyncAPIDeviceRegistrar: DeviceRegistrar {
    private let makeTransport: @Sendable (URL) -> any HTTPTransport

    public init(
        makeTransport: @escaping @Sendable (URL) -> any HTTPTransport = { URLSessionHTTPTransport(baseURL: $0) }
    ) {
        self.makeTransport = makeTransport
    }

    public func register(serverURL: URL, setupSecret: String, deviceName: String) async throws -> String {
        do {
            let response = try await SyncAPIClient.registerDevice(
                transport: makeTransport(serverURL), setupSecret: setupSecret, deviceName: deviceName)
            return response.token
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SyncFailure(error)
        }
    }
}
