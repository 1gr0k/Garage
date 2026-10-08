import Foundation
import GarageAPI
import GarageCore
import Testing

@testable import GarageSync

/// Терпимое чтение контракта движком (docs/api.md, «Правила эволюции контракта»).
private let vehicleRef = ref(.vehicle, IDs.vehicle)
private let recordRef = ref(.serviceRecord, IDs.record)

private let knownVehicleChange = """
    {"version":1,"modifiedAt":"2026-10-07T09:00:00.000Z","op":"upsert","entity":"vehicle",
     "data":{"id":"11111111-1111-4111-8111-111111111111","kind":"car","make":"Toyota","model":"Land Cruiser",
             "year":2019,"mileageKm":87400}}
    """

private func respond(_ json: String) -> FakeHTTPTransport.Step {
    .respond(200, Data(json.utf8))
}

private func pushedChangeIDs(_ request: HTTPRequest) throws -> [UUID] {
    let body = try #require(request.body)
    return try APICoding.makeDecoder().decode(PushRequest.self, from: body).changes.map(\.changeID)
}

@Suite struct ToleranceTests {
    // T1, T2
    @Test func pullSkipsUnknownEntityAndOpAndKeepsCursor() async throws {
        let store = InMemorySyncStore()
        let transport = FakeHTTPTransport([
            respond(
                """
                {"changes":[\(knownVehicleChange),
                  {"version":2,"modifiedAt":"2026-10-07T09:01:00.000Z","op":"upsert","entity":"futureEntity","data":{}},
                  {"version":3,"modifiedAt":"2026-10-07T09:02:00.000Z","op":"patch","entity":"vehicle"}],
                 "cursor":"3","hasMore":false}
                """)
        ])
        let report = try await makeEngine(store, transport).sync()

        #expect(report.skippedUnrecognized == ["entity:futureEntity", "op:patch"])
        #expect(report.pulled == 1)
        #expect(report.skipped.isEmpty)
        #expect(await store.vehicle(IDs.vehicle) != nil)
        #expect(await store.cursor() == "3")
    }

    /// Положительный контроль: битое изменение известного вида по-прежнему валит синхронизацию.
    @Test func pullWithMalformedKnownChangeStillFails() async throws {
        let store = InMemorySyncStore()
        let transport = FakeHTTPTransport([
            respond(
                """
                {"changes":[{"version":2,"modifiedAt":"2026-10-07T09:01:00.000Z","op":"upsert","entity":"vehicle"}],
                 "cursor":"2","hasMore":false}
                """)
        ])
        do {
            _ = try await makeEngine(store, transport).sync()
            Issue.record("expected an error")
        } catch is DecodingError {
            #expect(await store.cursor() == nil)
        }
    }

    // T3
    @Test func unrecognizedPushStatusKeepsChangeQueuedAndResendsItWithSameChangeID() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        let transport = FakeHTTPTransport([
            respond(#"{"results":[{"changeID":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","status":"postponed"}]}"#),
            try .json(emptyPull(cursor: "1")),
        ])
        let engine = makeEngine(store, transport)
        let first = try await engine.sync()

        #expect(first.unrecognizedOutcomes.map(\.ref) == [vehicleRef])
        #expect(first.unrecognizedOutcomes.map(\.status) == ["postponed"])
        #expect(first.pushed == 0)
        #expect(first.stillPending.map(\.changeID) == [IDs.changeA])
        #expect(await store.pendingChanges().map(\.changeID) == [IDs.changeA])
        #expect(await store.vehicle(IDs.vehicle) != nil)

        await transport.enqueue(try .json(PushResponse(results: [applied(IDs.changeA, 3)])))
        await transport.enqueue(try .json(emptyPull(cursor: "3")))
        let second = try await engine.sync()

        let requests = await transport.requests
        #expect(try pushedChangeIDs(requests[2]) == [IDs.changeA])
        #expect(second.pushed == 1)
        #expect(second.unrecognizedOutcomes.isEmpty)
        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.version(of: vehicleRef) == 3)
    }

    @Test func unrecognizedPushStatusDoesNotBlockNeighbours() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        await store.upsertLocal(
            .serviceRecord(makeRecord(), RecordSyncExtras()), modifiedAt: date("2026-10-07T10:01:00.000Z"),
            changeID: IDs.changeB)
        let transport = FakeHTTPTransport([
            try .json(
                PushResponse(results: [
                    PushResult(changeID: IDs.changeA, outcome: .unrecognized(status: "postponed")),
                    applied(IDs.changeB, 5),
                ])),
            try .json(emptyPull(cursor: "5")),
        ])
        let report = try await makeEngine(store, transport).sync()

        #expect(report.pushed == 1)
        #expect(await store.pendingChanges().map(\.changeID) == [IDs.changeA])
        #expect(await store.version(of: recordRef) == 5)
        #expect(await store.cursor() == "5")
    }

    /// Незнакомый исход не отправляется повторно в следующих раундах того же прогона.
    @Test func unrecognizedChangeIsNotResentInLaterRoundsOfTheSameRun() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        await store.setVersion(5, of: recordRef)
        await store.upsertLocal(
            .serviceRecord(makeRecord(), RecordSyncExtras()), modifiedAt: date("2026-10-07T10:01:00.000Z"),
            changeID: IDs.changeB)
        // Сервер сообщает о конфликте записи, наша правка новее → перебазирование и второй раунд.
        let current = ServerChange(
            version: 9, modifiedAt: date("2026-10-07T09:00:00.000Z"),
            operation: .upsert(
                .serviceRecord(ServiceRecordDTO(makeRecord(notes: "старое"), extras: RecordSyncExtras()))))
        let transport = FakeHTTPTransport([
            try .json(
                PushResponse(results: [
                    PushResult(changeID: IDs.changeA, outcome: .unrecognized(status: "postponed")),
                    PushResult(changeID: IDs.changeB, outcome: .conflict(reason: .versionMismatch, current: current)),
                ])),
            try .json(PushResponse(results: [applied(IDs.changeB, 10)])),
            try .json(emptyPull(cursor: "10")),
        ])
        let report = try await makeEngine(store, transport).sync()

        let requests = await transport.requests
        #expect(try pushedChangeIDs(requests[0]) == [IDs.changeA, IDs.changeB])
        #expect(try pushedChangeIDs(requests[1]) == [IDs.changeB])
        #expect(report.unrecognizedOutcomes.count == 1)
        #expect(report.stillPending.map(\.changeID) == [IDs.changeA])
    }

    // T4
    @Test func conflictWithUnrecognizedCurrentKeepsChangeQueued() async throws {
        let store = InMemorySyncStore()
        await store.setVersion(5, of: vehicleRef)
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        let transport = FakeHTTPTransport([
            respond(
                """
                {"results":[{"changeID":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","status":"conflict",
                  "reason":"versionMismatch","current":{"version":9,"modifiedAt":"2026-10-07T11:00:00.000Z",
                  "op":"upsert","entity":"futureEntity","data":{}}}]}
                """),
            try .json(emptyPull(cursor: "9")),
        ])
        let report = try await makeEngine(store, transport).sync()

        #expect(report.unrecognizedOutcomes.map(\.status) == ["conflict/entity:futureEntity"])
        #expect(report.conflictsResolved == 0)
        #expect(await store.pendingChanges().map(\.changeID) == [IDs.changeA])
        #expect(await store.version(of: vehicleRef) == 5)
    }

    // T6
    @Test func rejectedWithUnknownCodeTakesTheGeneralBranch() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .serviceRecord(makeRecord(), RecordSyncExtras()), modifiedAt: date("2026-10-07T11:00:00.000Z"),
            changeID: IDs.changeA)
        let error = APIError(code: .unknown("teapot"), message: "I am a teapot")
        let transport = FakeHTTPTransport([
            try .json(PushResponse(results: [PushResult(changeID: IDs.changeA, outcome: .rejected(error))])),
            try .json(emptyPull(cursor: "1")),
        ])
        let report = try await makeEngine(store, transport).sync()

        #expect(report.rejected.count == 1)
        #expect(report.rejected.first?.error.code == .unknown("teapot"))
        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.stored(IDs.record) != nil)
    }

    /// Положительный контроль к предыдущему: известный код `vehicleNotFound` по-прежнему удаляет запись локально.
    @Test func rejectedVehicleNotFoundStillDeletesRecordLocally() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .serviceRecord(makeRecord(), RecordSyncExtras()), modifiedAt: date("2026-10-07T11:00:00.000Z"),
            changeID: IDs.changeA)
        let error = APIError(code: .vehicleNotFound, message: "no vehicle")
        let transport = FakeHTTPTransport([
            try .json(PushResponse(results: [PushResult(changeID: IDs.changeA, outcome: .rejected(error))])),
            try .json(emptyPull(cursor: "1")),
        ])
        _ = try await makeEngine(store, transport).sync()

        #expect(await store.stored(IDs.record) == nil)
        #expect(await store.pendingChanges().isEmpty)
    }

    // T8: пример из docs/api.md читается как `.other`, сырая строка сохраняется и уходит обратно без изменений.
    @Test func goldenUnknownServiceTypeIsReadAsOtherAndSentBackUnchanged() throws {
        let data = try GoldenExamples.data("service-record-unknown-service-type")
        let dto = try APICoding.makeDecoder().decode(ServiceRecordDTO.self, from: data)
        let (record, extras) = try ServiceRecord.decoded(from: dto)

        #expect(record.serviceType == .other("coolant"))
        #expect(extras.rawServiceType == "coolant")
        let sent = ServiceRecordDTO(record, extras: extras)
        #expect(sent.serviceType == "coolant")
        #expect(try JSONValue(data: APICoding.makeEncoder().encode(sent)) == JSONValue(data: data))
    }

    private func applied(_ id: UUID, _ version: Int64) -> PushResult {
        PushResult(changeID: id, outcome: .applied(version: version))
    }
}
