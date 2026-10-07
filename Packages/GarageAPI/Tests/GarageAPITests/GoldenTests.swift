import Foundation
import Testing

@testable import GarageAPI

struct GoldenCase: Sendable, CustomTestStringConvertible {
    let name: String
    let check: @Sendable (Data) throws -> Void

    var testDescription: String { name }

    init<T: Codable & Equatable & Sendable>(_ name: String, _ expected: T) {
        self.name = name
        self.check = { data in
            let decoded = try APICoding.makeDecoder().decode(T.self, from: data)
            #expect(decoded == expected, "decode(golden) != expected for \(name)")
            let encoded = try APICoding.makeEncoder().encode(expected)
            #expect(
                try JSONValue(data: encoded) == JSONValue(data: data),
                "encode(expected) != golden for \(name)")
        }
    }
}

private func date(_ string: String) -> Date {
    try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
}

private func uuid(_ string: String) -> UUID { UUID(uuidString: string)! }

private let vehicleID = uuid("11111111-1111-4111-8111-111111111111")
private let recordID = uuid("22222222-2222-4222-8222-222222222222")

private let landCruiser = VehicleDTO(
    id: vehicleID, kind: "car", make: "Toyota", model: "Land Cruiser", year: 2019, mileageKm: 87_400)

private func oilChange(laborCostKopecks: Int, notes: String) -> ServiceRecordDTO {
    ServiceRecordDTO(
        id: recordID, vehicleID: vehicleID, date: date("2026-10-01T00:00:00.000Z"), mileageKm: 87_000,
        serviceType: "oilChange", laborCostKopecks: laborCostKopecks, notes: notes, parts: [])
}

private let goldenCases: [GoldenCase] = [
    GoldenCase(
        "vehicle",
        VehicleDTO(
            id: vehicleID, kind: "motorcycle", make: "Honda", model: "CB500X", year: 2021, mileageKm: 18_250)),
    GoldenCase(
        "service-record",
        ServiceRecordDTO(
            id: recordID, vehicleID: vehicleID, date: date("2026-10-01T00:00:00.000Z"), mileageKm: 87_000,
            serviceType: "brakes", laborCostKopecks: 350_000, notes: "Заменены колодки",
            parts: [
                PartDTO(
                    id: uuid("44444444-4444-4444-8444-444444444444"), name: "Колодки передние",
                    partNumber: "04465-60320", unitPriceKopecks: 520_000, quantity: 1),
                PartDTO(
                    id: uuid("55555555-5555-4555-8555-555555555555"), name: "Болт",
                    unitPriceKopecks: 15_000, quantity: 4),
            ],
            receipt: ReceiptRefDTO(
                sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", byteCount: 183_204))),
    GoldenCase(
        "register-device-request",
        RegisterDeviceRequest(setupSecret: "correct-horse-battery-staple", deviceName: "iPhone Андрея")),
    GoldenCase(
        "register-device-response",
        RegisterDeviceResponse(
            deviceID: uuid("66666666-6666-4666-8666-666666666666"),
            token: "q83vEjRZk1T7mP0cX2wYb9LdAaNfU5hGsKiOtVeJr4I")),
    GoldenCase(
        "pull-response",
        PullResponse(
            changes: [
                ServerChange(
                    version: 41, modifiedAt: date("2026-10-07T09:30:00.000Z"),
                    operation: .upsert(.vehicle(landCruiser))),
                ServerChange(
                    version: 42, modifiedAt: date("2026-10-07T09:31:00.000Z"),
                    operation: .upsert(.serviceRecord(oilChange(laborCostKopecks: 350_000, notes: "Заменено масло")))),
                ServerChange(
                    version: 43, modifiedAt: date("2026-10-07T09:32:00.000Z"),
                    operation: .delete(.serviceRecord, id: uuid("33333333-3333-4333-8333-333333333333"))),
            ],
            cursor: "43", hasMore: false)),
    GoldenCase(
        "push-request",
        PushRequest(changes: [
            PushChange(
                changeID: uuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), baseVersion: nil,
                modifiedAt: date("2026-10-07T09:30:00.000Z"), operation: .upsert(.vehicle(landCruiser))),
            PushChange(
                changeID: uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"), baseVersion: 42,
                modifiedAt: date("2026-10-07T10:00:00.000Z"),
                operation: .upsert(
                    .serviceRecord(oilChange(laborCostKopecks: 400_000, notes: "Заменено масло и фильтр")))),
            PushChange(
                changeID: uuid("cccccccc-cccc-4ccc-8ccc-cccccccccccc"), baseVersion: 7,
                modifiedAt: date("2026-10-07T10:01:00.000Z"),
                operation: .delete(.serviceRecord, id: uuid("33333333-3333-4333-8333-333333333333"))),
        ])),
    GoldenCase(
        "push-response",
        PushResponse(results: [
            PushResult(changeID: uuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), outcome: .applied(version: 44)),
            PushResult(
                changeID: uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
                outcome: .conflict(
                    reason: .versionMismatch,
                    current: ServerChange(
                        version: 45, modifiedAt: date("2026-10-07T09:45:00.000Z"),
                        operation: .upsert(
                            .serviceRecord(oilChange(laborCostKopecks: 350_000, notes: "Заменено масло")))))),
            PushResult(
                changeID: uuid("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
                outcome: .rejected(
                    APIError(
                        code: .vehicleNotFound,
                        message: "Vehicle 11111111-1111-4111-8111-111111111111 does not exist"))),
        ])),
    GoldenCase(
        "error-response",
        APIErrorResponse(
            error: APIError(
                code: .malformedRequest, message: "limit must be between 1 and 500",
                details: ["field": "limit"]))),
]

@Suite struct GoldenTests {
    @Test(arguments: goldenCases)
    func goldenExampleRoundTrips(_ goldenCase: GoldenCase) throws {
        try goldenCase.check(GoldenExamples.data(goldenCase.name))
    }

    @Test func goldenBlocksMatchTestTable() throws {
        let inDocument = Set(try GoldenExamples.load().keys)
        let inTests = Set(goldenCases.map(\.name))
        #expect(
            inDocument == inTests,
            "only in docs: \(inDocument.subtracting(inTests)), only in tests: \(inTests.subtracting(inDocument))")
    }
}

@Suite struct APICodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoding.makeDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func dateWithoutFractionalSecondsDecodes() throws {
        let value = try decode(
            ServerChange.self,
            #"{"version":1,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"vehicle","id":"11111111-1111-4111-8111-111111111111"}"#
        )
        #expect(value.modifiedAt == date("2026-10-07T09:30:00.000Z"))
    }

    @Test func dateEncodesWithMilliseconds() throws {
        let data = try APICoding.makeEncoder().encode(
            ServerChange(
                version: 1, modifiedAt: date("2026-10-07T09:30:00.000Z"), operation: .delete(.vehicle, id: vehicleID)))
        #expect(String(decoding: data, as: UTF8.self).contains("\"2026-10-07T09:30:00.000Z\""))
    }

    @Test func unknownOpFails() {
        #expect(throws: DecodingError.self) {
            try decode(
                ServerChange.self,
                #"{"version":1,"modifiedAt":"2026-10-07T09:30:00Z","op":"merge","entity":"vehicle","id":"11111111-1111-4111-8111-111111111111"}"#
            )
        }
    }

    @Test func unknownEntityFails() {
        #expect(throws: DecodingError.self) {
            try decode(
                ServerChange.self,
                #"{"version":1,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"part","id":"11111111-1111-4111-8111-111111111111"}"#
            )
        }
    }

    @Test func unknownPushStatusFails() {
        #expect(throws: DecodingError.self) {
            try decode(PushResult.self, #"{"changeID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","status":"postponed"}"#)
        }
    }

    @Test func unknownErrorCodeBecomesUnknown() throws {
        let response = try decode(APIErrorResponse.self, #"{"error":{"code":"teapot","message":"x"}}"#)
        #expect(response.error.code == .unknown("teapot"))
        #expect(response.error.code.httpStatus == nil)
    }

    @Test func unknownKeysAndNullAreTolerated() throws {
        let part = try decode(
            PartDTO.self,
            #"{"id":"44444444-4444-4444-8444-444444444444","name":"Болт","partNumber":null,"unitPriceKopecks":1,"quantity":2,"extra":true}"#
        )
        #expect(part.partNumber == nil)
    }

    @Test func nilFieldsAreOmitted() throws {
        let part = PartDTO(id: vehicleID, name: "Болт", unitPriceKopecks: 1, quantity: 1)
        let text = String(decoding: try APICoding.makeEncoder().encode(part), as: UTF8.self)
        #expect(!text.contains("partNumber"))
        let create = PushChange(
            changeID: vehicleID, baseVersion: nil, modifiedAt: date("2026-10-07T09:30:00.000Z"),
            operation: .delete(.vehicle, id: vehicleID))
        #expect(!String(decoding: try APICoding.makeEncoder().encode(create), as: UTF8.self).contains("baseVersion"))
    }

    @Test func errorCodesMapToHTTPStatus() {
        let table: [(APIErrorCode, Int?)] = [
            (.malformedRequest, 400), (.unauthorized, 401), (.invalidSetupSecret, 401),
            (.notFound, 404), (.cursorExpired, 410), (.payloadTooLarge, 413),
            (.unsupportedMediaType, 415), (.hashMismatch, 422), (.upgradeRequired, 426),
            (.internal, 500), (.validationFailed, nil), (.vehicleNotFound, nil), (.receiptNotFound, nil),
        ]
        for (code, status) in table {
            #expect(code.httpStatus == status, "\(code)")
            #expect(APIErrorCode(rawValue: code.rawValue) == code)
        }
    }

    @Test func unknownConflictReasonBecomesUnknown() throws {
        let result = try decode(
            PushResult.self,
            #"{"changeID":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","status":"conflict","reason":"locked","current":{"version":1,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"vehicle","id":"11111111-1111-4111-8111-111111111111"}}"#
        )
        guard case .conflict(let reason, let current) = result.outcome else {
            Issue.record("expected conflict")
            return
        }
        #expect(reason == .unknown("locked"))
        #expect(current.version == 1)
        let encoded = String(decoding: try APICoding.makeEncoder().encode(result), as: UTF8.self)
        #expect(encoded.contains(#""reason":"locked""#))
    }

    @Test func explicitNullBaseVersionAndLowercaseUUIDDecode() throws {
        let change = try decode(
            PushChange.self,
            #"{"changeID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","baseVersion":null,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"vehicle","id":"11111111-1111-4111-8111-111111111111"}"#
        )
        #expect(change.baseVersion == nil)
        #expect(change.changeID == uuid("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
    }

    @Test func incompleteOperationsFail() {
        #expect(throws: DecodingError.self) {
            try decode(
                ServerChange.self,
                #"{"version":1,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"vehicle"}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(
                ServerChange.self,
                #"{"version":1,"modifiedAt":"2026-10-07T09:30:00Z","op":"upsert","entity":"vehicle"}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(PushResult.self, #"{"changeID":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","status":"applied"}"#)
        }
    }

    @Test func receiptPathUsesHash() {
        #expect(APIPath.receipt(sha256: "abc") == "/v1/receipts/abc")
    }
}
