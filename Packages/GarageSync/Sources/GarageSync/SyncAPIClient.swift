import Foundation
import GarageAPI

public enum SyncError: Error, Sendable {
    /// A non-2xx response with a decodable `APIErrorResponse` body.
    case api(status: Int, APIError)
    /// A non-2xx response without a decodable error body.
    case http(status: Int)
    case malformedResponse
}

public struct SyncAPIClient: Sendable {
    private let transport: any HTTPTransport
    private let token: String

    public init(transport: any HTTPTransport, token: String) {
        self.transport = transport
        self.token = token
    }

    public func pull(after cursor: String?, limit: Int) async throws -> PullResponse {
        var query: [URLQueryItem] = []
        // Values are percent-encoded here (URLComponents leaves `+` and `&` alone).
        if let cursor { query.append(URLQueryItem(name: APIPath.afterQuery, value: Self.encode(cursor))) }
        query.append(URLQueryItem(name: APIPath.limitQuery, value: String(limit)))
        let response = try await send(HTTPRequest(method: "GET", path: APIPath.changes, query: query))
        return try APICoding.makeDecoder().decode(PullResponse.self, from: response.body)
    }

    public func push(_ request: PushRequest) async throws -> PushResponse {
        let body = try APICoding.makeEncoder().encode(request)
        let response = try await send(
            HTTPRequest(
                method: "POST", path: APIPath.changes, headers: ["Content-Type": "application/json"], body: body))
        return try APICoding.makeDecoder().decode(PushResponse.self, from: response.body)
    }

    /// `POST /v1/devices`: the only call without a token.
    public static func registerDevice(
        transport: any HTTPTransport, setupSecret: String, deviceName: String
    ) async throws -> RegisterDeviceResponse {
        let body = try APICoding.makeEncoder().encode(
            RegisterDeviceRequest(setupSecret: setupSecret, deviceName: deviceName))
        let response = try await transport.send(
            HTTPRequest(
                method: "POST", path: APIPath.devices, headers: ["Content-Type": "application/json"], body: body))
        try validate(response)
        return try APICoding.makeDecoder().decode(RegisterDeviceResponse.self, from: response.body)
    }

    /// `PUT /v1/receipts/{sha256}`; `200` (already there) and `201` are both success.
    public func uploadReceipt(sha256: String, data: Data) async throws {
        _ = try await send(
            HTTPRequest(
                method: "PUT", path: APIPath.receipt(sha256: sha256), headers: ["Content-Type": "image/jpeg"],
                body: data))
    }

    public func downloadReceipt(sha256: String) async throws -> Data {
        try await send(HTTPRequest(method: "GET", path: APIPath.receipt(sha256: sha256))).body
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var request = request
        request.headers["Authorization"] = "Bearer \(token)"
        let response = try await transport.send(request)
        try Self.validate(response)
        return response
    }

    private static func validate(_ response: HTTPResponse) throws {
        guard (200..<300).contains(response.status) else {
            if let decoded = try? APICoding.makeDecoder().decode(APIErrorResponse.self, from: response.body) {
                throw SyncError.api(status: response.status, decoded.error)
            }
            throw SyncError.http(status: response.status)
        }
    }
}
