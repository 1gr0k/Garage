import Foundation
import GarageAPI
import Testing
import Vapor
import VaporTesting

@testable import App

let testSetupSecret = "test-setup-secret"

struct TestFailure: Error, CustomStringConvertible {
    var description: String
}

/// Client of the app under test: requests and responses go through the GarageAPI DTOs.
struct TestClient: Sendable {
    let app: Application
    var token: String?

    func raw(
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        authorized: Bool = true
    ) async throws -> TestingHTTPResponse {
        var headers = headers
        if authorized, let token {
            headers.bearerAuthorization = BearerAuthorization(token: token)
        }
        return try await app.testing().sendRequest(method, path, headers: headers, body: body)
    }

    func json(
        _ method: HTTPMethod, _ path: String, _ value: some Encodable, authorized: Bool = true
    ) async throws -> TestingHTTPResponse {
        var headers = HTTPHeaders()
        headers.contentType = .json
        let body = ByteBuffer(data: try APICoding.makeEncoder().encode(value))
        return try await raw(method, path, headers: headers, body: body, authorized: authorized)
    }

    func decode<T: Decodable>(_ type: T.Type, _ response: TestingHTTPResponse) throws -> T {
        try APICoding.makeDecoder().decode(type, from: Data(response.body.readableBytesView))
    }

    func apiError(_ response: TestingHTTPResponse) throws -> APIError {
        try decode(APIErrorResponse.self, response).error
    }

    func register(secret: String = testSetupSecret, name: String = "Test iPhone") async throws -> TestingHTTPResponse {
        try await json(
            .POST, APIPath.devices, RegisterDeviceRequest(setupSecret: secret, deviceName: name), authorized: false)
    }

    func push(_ changes: [PushChange]) async throws -> [PushResult] {
        let response = try await json(.POST, APIPath.changes, PushRequest(changes: changes))
        try #require(response.status == .ok)
        return try decode(PushResponse.self, response).results
    }

    func push(_ change: PushChange) async throws -> PushResult {
        try await push([change])[0]
    }

    func pull(after: String? = nil, limit: Int? = nil) async throws -> PullResponse {
        let response = try await pullRaw(after: after, limit: limit)
        try #require(response.status == .ok)
        return try decode(PullResponse.self, response)
    }

    func pullRaw(after: String? = nil, limit: Int? = nil) async throws -> TestingHTTPResponse {
        var items: [String] = []
        if let after { items.append("after=\(after)") }
        if let limit { items.append("limit=\(limit)") }
        let query = items.isEmpty ? "" : "?" + items.joined(separator: "&")
        return try await raw(.GET, APIPath.changes + query)
    }

    func putReceipt(
        _ bytes: [UInt8], sha256: String? = nil, contentType: String? = "image/jpeg", authorized: Bool = true
    ) async throws -> TestingHTTPResponse {
        var headers = HTTPHeaders()
        if let contentType { headers.replaceOrAdd(name: .contentType, value: contentType) }
        return try await raw(
            .PUT, APIPath.receipt(sha256: sha256 ?? Hashing.sha256Hex(bytes)), headers: headers,
            body: ByteBuffer(bytes: bytes), authorized: authorized)
    }
}

/// In-memory app with a registered device.
func withTestApp(_ test: (Application, TestClient) async throws -> Void) async throws {
    try await withApp { app in
        try await configure(app, configuration: ServerConfiguration(storage: .memory, setupSecret: testSetupSecret))
        var client = TestClient(app: app)
        let response = try await client.register()
        try #require(response.status == .created)
        client.token = try client.decode(RegisterDeviceResponse.self, response).token
        try await test(app, client)
    }
}

// MARK: - Fixtures

enum Fixture {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]

    static func vehicle(
        id: UUID = UUID(), kind: String = "car", mileageKm: Int = 1000, year: Int = 2020
    ) -> VehicleDTO {
        VehicleDTO(id: id, kind: kind, make: "Toyota", model: "Corolla", year: year, mileageKm: mileageKm)
    }

    static func record(
        id: UUID = UUID(), vehicleID: UUID, mileageKm: Int = 500, serviceType: String = "oilChange",
        notes: String = "", parts: [PartDTO] = [], receipt: ReceiptRefDTO? = nil
    ) -> ServiceRecordDTO {
        ServiceRecordDTO(
            id: id, vehicleID: vehicleID, date: date, mileageKm: mileageKm, serviceType: serviceType,
            laborCostKopecks: 100_000, notes: notes, parts: parts, receipt: receipt)
    }

    static func upsert(
        _ dto: VehicleDTO, base: Int64? = nil, changeID: UUID = UUID(), at modifiedAt: Date = date
    ) -> PushChange {
        PushChange(changeID: changeID, baseVersion: base, modifiedAt: modifiedAt, operation: .upsert(.vehicle(dto)))
    }

    static func upsert(
        _ dto: ServiceRecordDTO, base: Int64? = nil, changeID: UUID = UUID(), at modifiedAt: Date = date
    ) -> PushChange {
        PushChange(
            changeID: changeID, baseVersion: base, modifiedAt: modifiedAt, operation: .upsert(.serviceRecord(dto)))
    }

    static func delete(
        _ kind: EntityKind, _ id: UUID, base: Int64? = nil, changeID: UUID = UUID(), at modifiedAt: Date = date
    ) -> PushChange {
        PushChange(changeID: changeID, baseVersion: base, modifiedAt: modifiedAt, operation: .delete(kind, id: id))
    }
}

// MARK: - Result accessors

extension PushResult {
    func appliedVersion() throws -> Int64 {
        guard case .applied(let version) = outcome else {
            throw TestFailure(description: "expected applied, got \(outcome)")
        }
        return version
    }

    func conflict() throws -> (reason: ConflictReason, current: ServerChange) {
        guard case .conflict(let reason, let current) = outcome else {
            throw TestFailure(description: "expected conflict, got \(outcome)")
        }
        return (reason, current)
    }

    func rejection() throws -> APIError {
        guard case .rejected(let error) = outcome else {
            throw TestFailure(description: "expected rejected, got \(outcome)")
        }
        return error
    }
}

extension ServerChange {
    var upsertedPayload: EntityPayload? {
        if case .upsert(let payload) = operation { payload } else { nil }
    }
}
