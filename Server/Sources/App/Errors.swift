import Foundation
import GarageAPI
import Vapor

/// An error that is rendered as the API error body `{"error":{code,message,details?}}`.
struct ServerError: Error, Sendable {
    var api: APIError

    init(_ code: APIErrorCode, _ message: String, details: [String: String]? = nil) {
        api = APIError(code: code, message: message, details: details)
    }

    static func malformed(_ message: String, field: String? = nil) -> ServerError {
        ServerError(.malformedRequest, message, details: field.map { ["field": $0] })
    }

    static let unauthorized = ServerError(.unauthorized, "Missing or invalid bearer token")
    static let invalidSetupSecret = ServerError(.invalidSetupSecret, "Invalid setup secret")
    static let notFound = ServerError(.notFound, "Not found")
    static let internalError = ServerError(.internal, "Internal server error")
}

/// Turns any error into an `APIErrorResponse`; the real cause of a 500 is only logged.
struct APIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            return Self.response(for: error, request: request)
        }
    }

    static func response(for error: any Error, request: Request) -> Response {
        let apiError = map(error, logger: request.logger)
        var headers = HTTPHeaders()
        headers.contentType = .json
        let body = (try? APICoding.makeEncoder().encode(APIErrorResponse(error: apiError))) ?? Data()
        return Response(
            status: HTTPResponseStatus(statusCode: apiError.code.httpStatus ?? 500),
            headers: headers,
            body: .init(data: body)
        )
    }

    static func map(_ error: any Error, logger: Logger) -> APIError {
        if let error = error as? ServerError {
            return error.api
        }
        if let error = error as? DecodingError {
            return ServerError.malformed(describe(error)).api
        }
        if let abort = error as? any AbortError {
            switch abort.status.code {
            case 404: return ServerError.notFound.api
            case 413: return ServerError(.payloadTooLarge, "Payload too large").api
            case 415: return ServerError(.unsupportedMediaType, abort.reason).api
            case 400..<500: return ServerError.malformed(abort.reason).api
            default: break
            }
        }
        logger.error("Unhandled error: \(String(reflecting: error))")
        return ServerError.internalError.api
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        let (context, summary): (DecodingError.Context, String)
        switch error {
        case .keyNotFound(let key, let c): (context, summary) = (c, "missing key \"\(key.stringValue)\"")
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            (context, summary) = (c, c.debugDescription)
        @unknown default: return "Malformed request body"
        }
        let location = path(context)
        return location.isEmpty ? summary : "\(summary) at \(location)"
    }
}
