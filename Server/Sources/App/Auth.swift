import Fluent
import Vapor

struct DeviceAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        let hash = Hashing.sha256Hex(bearer.token)
        if let device = try await Device.query(on: request.db).filter(\.$tokenHash == hash).first() {
            request.auth.login(device)
        }
    }
}

/// Rejects requests that no authenticator logged in, with the API error body.
struct RequireDeviceMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.auth.has(Device.self) else { throw ServerError.unauthorized }
        return try await next.respond(to: request)
    }
}
