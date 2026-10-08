import Foundation
import Testing

@testable import GarageAPI

struct GoldenCase: Sendable, CustomTestStringConvertible {
    let name: String
    let check: @Sendable (Data) throws -> Void

    var testDescription: String { name }

    init(name: String, check: @escaping @Sendable (Data) throws -> Void) {
        self.name = name
        self.check = check
    }

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

extension GoldenCase {
    /// Пример, у которого круговой проход невозможен (пропущенные элементы): только декодирование,
    /// ожидаемое значение задаёт тест, а JSON берётся из `docs/api.md`.
    init<T: Decodable & Equatable & Sendable>(decodeOnly name: String, _ expected: T) {
        self.init(name: name) { data in
            let decoded = try APICoding.makeDecoder().decode(T.self, from: data)
            #expect(decoded == expected, "decode(golden) != expected for \(name)")
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
            PushChange(
                changeID: uuid("dddddddd-dddd-4ddd-8ddd-dddddddddddd"), baseVersion: nil,
                modifiedAt: date("2026-10-07T10:02:00.000Z"),
                operation: .upsert(
                    .serviceRecord(
                        ServiceRecordDTO(
                            id: uuid("77777777-7777-4777-8777-777777777777"),
                            vehicleID: uuid("99999999-9999-4999-8999-999999999999"),
                            date: date("2026-10-02T00:00:00.000Z"), mileageKm: 5_200,
                            serviceType: "chain", laborCostKopecks: 120_000, notes: "Замена цепи",
                            parts: [])))),
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
                changeID: uuid("cccccccc-cccc-4ccc-8ccc-cccccccccccc"), outcome: .applied(version: 46)),
            PushResult(
                changeID: uuid("dddddddd-dddd-4ddd-8ddd-dddddddddddd"),
                outcome: .rejected(
                    APIError(
                        code: .vehicleNotFound,
                        message: "Vehicle 99999999-9999-4999-8999-999999999999 does not exist"))),
        ])),
    GoldenCase(
        decodeOnly: "pull-response-unknown-entity",
        PullResponse(
            changes: [
                ServerChange(
                    version: 41, modifiedAt: date("2026-10-07T09:30:00.000Z"),
                    operation: .upsert(.vehicle(landCruiser))),
                ServerChange(
                    version: 43, modifiedAt: date("2026-10-07T09:32:00.000Z"),
                    operation: .delete(.serviceRecord, id: uuid("33333333-3333-4333-8333-333333333333"))),
            ],
            cursor: "43", hasMore: false, skipped: ["entity:futureEntity"])),
    GoldenCase(
        decodeOnly: "pull-response-unknown-op",
        PullResponse(
            changes: [
                ServerChange(
                    version: 41, modifiedAt: date("2026-10-07T09:30:00.000Z"),
                    operation: .upsert(.vehicle(landCruiser))),
                ServerChange(
                    version: 43, modifiedAt: date("2026-10-07T09:32:00.000Z"),
                    operation: .delete(.serviceRecord, id: uuid("33333333-3333-4333-8333-333333333333"))),
            ],
            cursor: "43", hasMore: false, skipped: ["op:patch"])),
    GoldenCase(
        decodeOnly: "push-response-unknown-status",
        PushResponse(results: [
            PushResult(changeID: uuid("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), outcome: .applied(version: 44)),
            PushResult(
                changeID: uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"), outcome: .unrecognized(status: "postponed")),
            PushResult(
                changeID: uuid("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
                outcome: .unrecognized(status: "conflict/entity:futureEntity")),
            PushResult(changeID: uuid("dddddddd-dddd-4ddd-8ddd-dddddddddddd"), outcome: .applied(version: 46)),
        ])),
    GoldenCase(
        "push-response-unknown-conflict-reason",
        PushResponse(results: [
            PushResult(
                changeID: uuid("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
                outcome: .conflict(
                    reason: .unknown("locked"),
                    current: ServerChange(
                        version: 45, modifiedAt: date("2026-10-07T09:45:00.000Z"),
                        operation: .upsert(
                            .serviceRecord(oilChange(laborCostKopecks: 350_000, notes: "Заменено масло"))))))
        ])),
    GoldenCase(
        "push-response-unknown-error-code",
        PushResponse(results: [
            PushResult(
                changeID: uuid("dddddddd-dddd-4ddd-8ddd-dddddddddddd"),
                outcome: .rejected(APIError(code: .unknown("teapot"), message: "I am a teapot")))
        ])),
    GoldenCase(
        "service-record-unknown-service-type",
        ServiceRecordDTO(
            id: recordID, vehicleID: vehicleID, date: date("2026-10-01T00:00:00.000Z"), mileageKm: 87_000,
            serviceType: "coolant", laborCostKopecks: 0, notes: "", parts: [])),
    GoldenCase(
        "maintenance-rule",
        MaintenanceRuleDTO(
            id: uuid("88888888-8888-4888-8888-888888888888"), vehicleID: vehicleID, serviceType: "oilChange",
            period: "months:12", distanceKm: 10_000, startDate: date("2026-10-08T00:00:00.000Z"),
            startMileageKm: 87_400)),
    GoldenCase(
        "maintenance-rule-unknown-period",
        MaintenanceRuleDTO(
            id: uuid("88888888-8888-4888-8888-888888888888"), vehicleID: vehicleID, serviceType: "oilChange",
            period: "weeks:2", startDate: date("2026-10-08T00:00:00.000Z"), startMileageKm: 87_400)),
    GoldenCase(
        "vehicle-unknown-kind",
        VehicleDTO(id: vehicleID, kind: "tractor", make: "Fendt", model: "Vario", year: 2020, mileageKm: 1_200)),
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

    @Test func dateIsRoundedToNearestMillisecondAndRoundTripsStably() throws {
        let base = date("2026-10-07T09:30:00.000Z")
        let cases: [(fraction: Double, expected: String)] = [
            (0.1236, "2026-10-07T09:30:00.124Z"),
            (0.1234, "2026-10-07T09:30:00.123Z"),
            (0.9996, "2026-10-07T09:30:01.000Z"),
        ]
        for (fraction, expected) in cases {
            let change = ServerChange(
                version: 1, modifiedAt: base.addingTimeInterval(fraction),
                operation: .delete(.vehicle, id: vehicleID))
            let first = try APICoding.makeEncoder().encode(change)
            #expect(String(decoding: first, as: UTF8.self).contains("\"\(expected)\""), "for \(fraction)")

            let decoded = try APICoding.makeDecoder().decode(ServerChange.self, from: first)
            let second = try APICoding.makeEncoder().encode(decoded)
            #expect(first == second, "encode(decode(encode)) differs for \(fraction)")
        }
    }

    private func pullJSON(_ changes: String) -> String {
        #"{"changes":[\#(changes)],"cursor":"9","hasMore":false}"#
    }

    private static let knownDelete =
        #"{"version":1,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"vehicle","id":"11111111-1111-4111-8111-111111111111"}"#
    private static let knownDelete2 =
        #"{"version":4,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"serviceRecord","id":"33333333-3333-4333-8333-333333333333"}"#

    @Test func unknownEntityAndOpAreSkippedBetweenKnownChanges() throws {
        let unknownEntity =
            #"{"version":2,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"part","id":"11111111-1111-4111-8111-111111111111"}"#
        let unknownOp =
            #"{"version":3,"modifiedAt":"2026-10-07T09:30:00Z","op":"patch","entity":"vehicle","id":"11111111-1111-4111-8111-111111111111"}"#
        let response = try decode(
            PullResponse.self,
            pullJSON([Self.knownDelete, unknownEntity, unknownOp, Self.knownDelete2].joined(separator: ",")))
        #expect(response.changes.map(\.version) == [1, 4])
        #expect(response.skipped == ["entity:part", "op:patch"])
        #expect(response.cursor == "9")
    }

    private static let ruleDTO = MaintenanceRuleDTO(
        id: uuid("88888888-8888-4888-8888-888888888888"), vehicleID: vehicleID, serviceType: "oilChange",
        period: "months:12", distanceKm: 10_000, startDate: date("2026-10-08T00:00:00.000Z"), startMileageKm: 87_400)

    /// С включением вида `maintenanceRule` (этап 12, часть S) правило — известный вид, а `futureEntity` по-прежнему
    /// пропускается: ответ того же вида, что `pull-response-unknown-entity`, но с правилом в середине.
    @Test func maintenanceRuleIsKnownWhileFutureEntityIsStillSkipped() throws {
        let rule = ServerChange(
            version: 42, modifiedAt: date("2026-10-07T09:31:00.000Z"),
            operation: .upsert(.maintenanceRule(Self.ruleDTO)))
        let ruleJSON = String(decoding: try APICoding.makeEncoder().encode(rule), as: UTF8.self)
        let future =
            #"{"version":44,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"futureEntity","id":"11111111-1111-4111-8111-111111111111"}"#
        let response = try decode(
            PullResponse.self, pullJSON([Self.knownDelete, ruleJSON, future, Self.knownDelete2].joined(separator: ",")))
        #expect(response.changes.map(\.version) == [1, 42, 4])
        #expect(response.changes[1].operation == .upsert(.maintenanceRule(Self.ruleDTO)))
        #expect(response.skipped == ["entity:futureEntity"])
    }

    @Test func maintenanceRuleOperationsRoundTrip() throws {
        let operations: [ChangeOperation] = [
            .upsert(.maintenanceRule(Self.ruleDTO)),
            .delete(.maintenanceRule, id: Self.ruleDTO.id),
        ]
        for operation in operations {
            let change = PushChange(
                changeID: vehicleID, baseVersion: 3, modifiedAt: date("2026-10-07T09:30:00.000Z"), operation: operation)
            let decoded = try APICoding.makeDecoder().decode(
                PushChange.self, from: try APICoding.makeEncoder().encode(change))
            #expect(decoded == change)
        }
        #expect(EntityPayload.maintenanceRule(Self.ruleDTO).kind == .maintenanceRule)
        #expect(EntityPayload.maintenanceRule(Self.ruleDTO).id == Self.ruleDTO.id)
        #expect(EntityKind.allCases.map(\.rawValue) == ["vehicle", "serviceRecord", "maintenanceRule"])
    }

    @Test func nothingSkippedMeansEmptySkipped() throws {
        let response = try decode(PullResponse.self, pullJSON(Self.knownDelete))
        #expect(response.skipped.isEmpty)
    }

    @Test func skippedIsNotPartOfTheWireFormat() throws {
        let response = PullResponse(changes: [], cursor: "1", hasMore: false, skipped: ["entity:futureEntity"])
        let text = String(decoding: try APICoding.makeEncoder().encode(response), as: UTF8.self)
        #expect(!text.contains("skipped"))
    }

    /// Положительный контроль строгости: терпимость только к незнакомому значению, не к нарушению формата.
    @Test func malformedElementsStillFailTheWholePullResponse() {
        let knownWithoutData =
            #"{"version":2,"modifiedAt":"2026-10-07T09:30:00Z","op":"upsert","entity":"vehicle"}"#
        let badDate =
            #"{"version":2,"modifiedAt":"yesterday","op":"delete","entity":"vehicle","id":"11111111-1111-4111-8111-111111111111"}"#
        let badID =
            #"{"version":2,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"vehicle","id":"not-a-uuid"}"#
        for broken in [knownWithoutData, badDate, badID] {
            #expect(throws: DecodingError.self, "\(broken)") {
                try decode(PullResponse.self, pullJSON([Self.knownDelete, broken].joined(separator: ",")))
            }
        }
    }

    /// Сервер строг к входящему: незнакомые `entity`/`op` в push-запросе — ошибка запроса, не пропуск.
    @Test func unknownEntityOrOpInPushRequestFails() {
        for (entity, op) in [("part", "delete"), ("vehicle", "merge")] {
            #expect(throws: DecodingError.self, "\(entity)/\(op)") {
                try decode(
                    PushChange.self,
                    #"{"changeID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","modifiedAt":"2026-10-07T09:30:00Z","op":"\#(op)","entity":"\#(entity)","id":"11111111-1111-4111-8111-111111111111"}"#
                )
            }
        }
    }

    @Test func strictErrorPointsAtTheOffendingKey() {
        func failingKey(entity: String, op: String) -> String? {
            do {
                _ = try decode(
                    PushChange.self,
                    #"{"changeID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","modifiedAt":"2026-10-07T09:30:00Z","op":"\#(op)","entity":"\#(entity)","id":"11111111-1111-4111-8111-111111111111"}"#
                )
                return nil
            } catch let DecodingError.dataCorrupted(context) {
                return context.codingPath.last?.stringValue
            } catch {
                return nil
            }
        }
        #expect(failingKey(entity: "part", op: "delete") == "entity")
        #expect(failingKey(entity: "vehicle", op: "merge") == "op")
    }

    @Test func unknownPushStatusBecomesUnrecognized() throws {
        let response = try decode(
            PushResponse.self,
            #"{"results":[{"changeID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","status":"postponed"},{"changeID":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","status":"applied","version":7}]}"#
        )
        #expect(response.results.map(\.outcome) == [.unrecognized(status: "postponed"), .applied(version: 7)])
        let encoded = String(decoding: try APICoding.makeEncoder().encode(response.results[0]), as: UTF8.self)
        #expect(encoded.contains(#""status":"postponed""#))
    }

    @Test func conflictWithUnrecognizedCurrentBecomesUnrecognized() throws {
        let response = try decode(
            PushResponse.self,
            #"{"results":[{"changeID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","status":"conflict","reason":"versionMismatch","current":{"version":2,"modifiedAt":"2026-10-07T09:30:00Z","op":"delete","entity":"part","id":"11111111-1111-4111-8111-111111111111"}},{"changeID":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","status":"conflict","reason":"deleted","current":{"version":3,"modifiedAt":"2026-10-07T09:30:00Z","op":"merge","entity":"vehicle","id":"11111111-1111-4111-8111-111111111111"}},{"changeID":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","status":"applied","version":7}]}"#
        )
        #expect(
            response.results.map(\.outcome) == [
                .unrecognized(status: "conflict/entity:part"), .unrecognized(status: "conflict/op:merge"),
                .applied(version: 7),
            ])
    }

    @Test func conflictWithMalformedCurrentStillFails() {
        #expect(throws: DecodingError.self) {
            try decode(
                PushResponse.self,
                #"{"results":[{"changeID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","status":"conflict","reason":"versionMismatch","current":{"version":2,"modifiedAt":"2026-10-07T09:30:00Z","op":"upsert","entity":"vehicle"}}]}"#
            )
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
