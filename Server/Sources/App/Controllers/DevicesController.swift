import Fluent
import Foundation
import GarageAPI
import Vapor

struct DevicesController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("v1", "devices", use: register)
    }

    @Sendable
    func register(_ request: Request) async throws -> Response {
        let body = try request.content.decode(RegisterDeviceRequest.self)
        guard Hashing.constantTimeEquals(body.setupSecret, request.application.setupSecret) else {
            throw ServerError.invalidSetupSecret
        }
        let name = body.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw ServerError.malformed("deviceName must not be empty", field: "deviceName")
        }

        let token = Hashing.makeToken()
        let device = Device(name: name, tokenHash: Hashing.sha256Hex(token))
        try await device.save(on: request.db)
        guard let id = device.id else { throw ServerError.internalError }
        return try jsonResponse(RegisterDeviceResponse(deviceID: id, token: token), status: .created)
    }
}
