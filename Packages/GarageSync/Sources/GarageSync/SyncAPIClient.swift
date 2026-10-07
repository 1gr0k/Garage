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
        if let cursor { query.append(URLQueryItem(name: APIPath.afterQuery, value: cursor)) }
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

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var request = request
        request.headers["Authorization"] = "Bearer \(token)"
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else {
            if let decoded = try? APICoding.makeDecoder().decode(APIErrorResponse.self, from: response.body) {
                throw SyncError.api(status: response.status, decoded.error)
            }
            throw SyncError.http(status: response.status)
        }
        return response
    }
}
