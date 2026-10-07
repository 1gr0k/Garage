import Fluent
import Foundation
import GarageAPI
import Testing
import Vapor
import VaporTesting

@testable import App

// MARK: - Auth

@Test func registrationWithWrongSecretIsRejected() async throws {
    try await withTestApp { app, client in
        let response = try await client.register(secret: "wrong")
        #expect(response.status == .unauthorized)
        #expect(try client.apiError(response).code == .invalidSetupSecret)
        #expect(try await Device.query(on: app.db).count() == 1)  // only the helper's device
    }
}

@Test func registrationRejectsEmptyDeviceName() async throws {
    try await withTestApp { _, client in
        let response = try await client.register(name: "  ")
        #expect(response.status == .badRequest)
        let error = try client.apiError(response)
        #expect(error.code == .malformedRequest)
        #expect(error.details?["field"] == "deviceName")
    }
}

@Test func tokenIsBase64URLAndOnlyItsHashIsStored() async throws {
    try await withTestApp { app, client in
        let response = try await client.register(name: "Second device")
        #expect(response.status == .created)
        let registration = try client.decode(RegisterDeviceResponse.self, response)

        #expect(registration.token.count == 43)
        #expect(registration.token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })

        let device = try #require(try await Device.find(registration.deviceID, on: app.db))
        #expect(device.name == "Second device")
        #expect(device.tokenHash == Hashing.sha256Hex(registration.token))
        #expect(device.tokenHash != registration.token)

        // The new token works.
        var second = client
        second.token = registration.token
        #expect(try await second.pull().changes.isEmpty)
    }
}

@Test func missingOrForeignTokenIsUnauthorized() async throws {
    try await withTestApp { _, client in
        var foreign = client
        foreign.token = "not-a-registered-token"
        for attempt in [try await client.raw(.GET, APIPath.changes, authorized: false), try await foreign.pullRaw()] {
            #expect(attempt.status == .unauthorized)
            #expect(try client.apiError(attempt).code == .unauthorized)
        }
        let push = try await client.json(.POST, APIPath.changes, PushRequest(changes: []), authorized: false)
        #expect(push.status == .unauthorized)
    }
}

@Test func receiptEndpointsRequireAuthentication() async throws {
    try await withTestApp { _, client in
        let sha = Hashing.sha256Hex(Fixture.jpeg)
        let put = try await client.putReceipt(Fixture.jpeg, authorized: false)
        #expect(put.status == .unauthorized)
        #expect(try client.apiError(put).code == .unauthorized)
        let get = try await client.raw(.GET, APIPath.receipt(sha256: sha), authorized: false)
        #expect(get.status == .unauthorized)
        #expect(try await Receipt.find(sha, on: client.app.db) == nil)
    }
}

@Test func unknownRouteReturnsApiErrorBody() async throws {
    try await withTestApp { _, client in
        let response = try await client.raw(.GET, "/v1/nothing")
        #expect(response.status == .notFound)
        #expect(try client.apiError(response).code == .notFound)
    }
}

// MARK: - Receipts

@Test func putReceiptCreatesThenReportsExisting() async throws {
    try await withTestApp { _, client in
        let first = try await client.putReceipt(Fixture.jpeg)
        #expect(first.status == .created)
        let second = try await client.putReceipt(Fixture.jpeg)
        #expect(second.status == .ok)
    }
}

@Test func putReceiptWithWrongHashIsUnprocessable() async throws {
    try await withTestApp { app, client in
        let wrong = Hashing.sha256Hex([1, 2, 3])
        let response = try await client.putReceipt(Fixture.jpeg, sha256: wrong)
        #expect(response.status == .unprocessableEntity)
        #expect(try client.apiError(response).code == .hashMismatch)
        #expect(try await Receipt.query(on: app.db).count() == 0)
    }
}

@Test func putReceiptRequiresJpegContentType() async throws {
    try await withTestApp { _, client in
        for contentType in ["image/png", "application/octet-stream", nil] {
            let response = try await client.putReceipt(Fixture.jpeg, contentType: contentType)
            #expect(response.status == .unsupportedMediaType)
            #expect(try client.apiError(response).code == .unsupportedMediaType)
        }
    }
}

@Test func putReceiptRejectsInvalidHashInPath() async throws {
    try await withTestApp { _, client in
        let uppercase = Hashing.sha256Hex(Fixture.jpeg).uppercased()
        for sha in [uppercase, "abc", String(repeating: "g", count: 64)] {
            let response = try await client.putReceipt(Fixture.jpeg, sha256: sha)
            #expect(response.status == .badRequest)
            #expect(try client.apiError(response).code == .malformedRequest)
        }
    }
}

@Test func receiptSizeLimitIsFiveMiB() async throws {
    try await withTestApp { _, client in
        let limit = APIPath.maxReceiptBytes
        let big = [UInt8](repeating: 7, count: limit + 1)
        let tooLarge = try await client.putReceipt(big)
        #expect(tooLarge.status == .payloadTooLarge)
        #expect(try client.apiError(tooLarge).code == .payloadTooLarge)

        let exact = [UInt8](repeating: 7, count: limit)
        #expect(try await client.putReceipt(exact).status == .created)
    }
}

@Test func getReceiptServesBytesWithCachingHeaders() async throws {
    try await withTestApp { _, client in
        _ = try await client.putReceipt(Fixture.jpeg)
        let sha = Hashing.sha256Hex(Fixture.jpeg)

        let response = try await client.raw(.GET, APIPath.receipt(sha256: sha))
        #expect(response.status == .ok)
        #expect(Array(response.body.readableBytesView) == Fixture.jpeg)
        #expect(response.headers.first(name: .contentType) == "image/jpeg")
        #expect(response.headers.first(name: .eTag) == "\"\(sha)\"")
        #expect(response.headers.first(name: .cacheControl) == "public, max-age=31536000, immutable")

        for validator in ["\"\(sha)\"", "W/\"\(sha)\"", "\"other\", \"\(sha)\"", "*"] {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .ifNoneMatch, value: validator)
            let cached = try await client.raw(.GET, APIPath.receipt(sha256: sha), headers: headers)
            #expect(cached.status == .notModified, "If-None-Match: \(validator)")
            #expect(cached.body.readableBytes == 0)
            #expect(cached.headers.first(name: .eTag) == "\"\(sha)\"")
        }

        var stale = HTTPHeaders()
        stale.replaceOrAdd(name: .ifNoneMatch, value: "\"other\"")
        #expect(try await client.raw(.GET, APIPath.receipt(sha256: sha), headers: stale).status == .ok)
    }
}

@Test func getMissingReceiptIsNotFound() async throws {
    try await withTestApp { _, client in
        let response = try await client.raw(.GET, APIPath.receipt(sha256: Hashing.sha256Hex([9])))
        #expect(response.status == .notFound)
        #expect(try client.apiError(response).code == .notFound)
    }
}

/// Сборки мусора для blob'ов нет (`docs/api.md`, «Вне скоупа»): каскад удаляет запись, но не её чек.
@Test func receiptBlobOutlivesCascadedRecord() async throws {
    try await withTestApp { _, client in
        #expect(try await client.putReceipt(Fixture.jpeg).status == .created)
        let sha = Hashing.sha256Hex(Fixture.jpeg)
        let vehicle = Fixture.vehicle()
        let record = Fixture.record(
            vehicleID: vehicle.id, receipt: ReceiptRefDTO(sha256: sha, byteCount: Fixture.jpeg.count))
        _ = try await client.push([Fixture.upsert(vehicle), Fixture.upsert(record)]).map { try $0.appliedVersion() }

        _ = try await client.push(Fixture.delete(.vehicle, vehicle.id)).appliedVersion()
        let cascaded = try await client.pull(after: "3")
        #expect(cascaded.changes.map(\.operation) == [.delete(.serviceRecord, id: record.id)])

        let response = try await client.raw(.GET, APIPath.receipt(sha256: sha))
        #expect(response.status == .ok)
        #expect(Array(response.body.readableBytesView) == Fixture.jpeg)
    }
}
