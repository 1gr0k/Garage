import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Own request/response types, so the fake transport and Linux do not depend on `URLRequest`.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    /// Item values are already percent-encoded.
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: String, path: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPTransport: HTTPTransport {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SyncError.malformedResponse
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + request.path
        components.percentEncodedQueryItems = request.query.isEmpty ? nil : request.query
        guard let url = components.url else { throw SyncError.malformedResponse }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw SyncError.malformedResponse }
        return HTTPResponse(status: http.statusCode, body: data)
    }
}
