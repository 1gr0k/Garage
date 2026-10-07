import Foundation
import GarageAPI
import GarageCore
import Testing

@testable import GarageSync

private let vehicleRef = ref(.vehicle, IDs.vehicle)
private let recordRef = ref(.serviceRecord, IDs.record)

private func serverChange(
    _ version: Int64, _ modifiedAt: String, _ entity: SyncEntity
) -> ServerChange {
    ServerChange(version: version, modifiedAt: date(modifiedAt), operation: .upsert(entity.payload))
}

private func tombstone(_ version: Int64, _ modifiedAt: String, _ ref: EntityRef) -> ServerChange {
    ServerChange(version: version, modifiedAt: date(modifiedAt), operation: .delete(ref.kind, id: ref.id))
}

private func conflict(_ reason: ConflictReason, _ current: ServerChange, id: UUID) -> PushResult {
    PushResult(changeID: id, outcome: .conflict(reason: reason, current: current))
}

@Suite struct SyncEngineTests {
    // 1
    @Test func pushThenPullMatchesGoldenExamples() async throws {
        let store = InMemorySyncStore()
        let remoteRecordRef = ref(.serviceRecord, IDs.deletedRecord)
        let orphanRef = ref(.serviceRecord, IDs.orphanRecord)

        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T09:30:00.000Z"), changeID: IDs.changeA)
        await store.setVersion(42, of: recordRef)
        let editedRecord = makeRecord(laborKopecks: 400_000, notes: "Заменено масло и фильтр")
        await store.upsertLocal(
            .serviceRecord(editedRecord, RecordSyncExtras()), modifiedAt: date("2026-10-07T10:00:00.000Z"),
            changeID: IDs.changeB)
        await store.setVersion(7, of: remoteRecordRef)
        await store.deleteLocal(remoteRecordRef, modifiedAt: date("2026-10-07T10:01:00.000Z"), changeID: IDs.changeC)
        let orphan = try ServiceRecord(
            id: IDs.orphanRecord, vehicleID: IDs.missingVehicle, date: date("2026-10-02T00:00:00.000Z"),
            mileageKm: 5_200, serviceType: .chain, laborCost: Money(kopecks: 120_000), notes: "Замена цепи")
        await store.upsertLocal(
            .serviceRecord(orphan, RecordSyncExtras()), modifiedAt: date("2026-10-07T10:02:00.000Z"),
            changeID: IDs.changeD)

        let transport = FakeHTTPTransport([
            try .golden("push-response"),
            try .json(PushResponse(results: [PushResult(changeID: IDs.changeB, outcome: .applied(version: 47))])),
            try .golden("pull-response"),
        ])
        let report = try await makeEngine(store, transport).sync()

        let requests = await transport.requests
        #expect(requests.count == 3)
        let firstBody = try #require(requests[0].body)
        #expect(try JSONValue(data: firstBody) == JSONValue(data: GoldenExamples.data("push-request")))
        #expect(requests[0].method == "POST")
        #expect(requests[0].headers["Authorization"] == "Bearer test-token")
        #expect(requests[0].headers["Content-Type"] == "application/json")

        let second = try decodePush(requests[1])
        let first = try decodePush(requests[0])
        #expect(second.changes.count == 1)
        #expect(second.changes[0].baseVersion == 45)
        #expect(second.changes[0].changeID == IDs.changeB)
        #expect(second.changes[0].operation == first.changes[1].operation)

        #expect(requests[2].method == "GET")
        #expect(requests[2].query.contains { $0.name == "after" } == false)
        #expect(requests[2].query.contains(URLQueryItem(name: "limit", value: "200")))
        #expect(requests[2].headers["Authorization"] != nil)

        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.version(of: vehicleRef) == 44)
        #expect(await store.version(of: recordRef) == 47)
        #expect(await store.version(of: remoteRecordRef) == 46)
        #expect(await store.version(of: orphanRef) == nil)
        #expect(await store.stored(IDs.orphanRecord) == nil)
        #expect(await store.stored(IDs.record)?.record == editedRecord)
        #expect(await store.vehicle(IDs.vehicle) == makeVehicle())
        #expect(await store.cursor() == "43")
        #expect(report.pushed == 3)
        #expect(report.pulled == 0)
        #expect(report.rejected.count == 1)
        #expect(report.rejected.first?.ref == orphanRef)
        #expect(report.rejected.first?.error.code == .vehicleNotFound)
    }

    // 2
    @Test func newDevicePullsEverything() async throws {
        let store = InMemorySyncStore()
        let transport = FakeHTTPTransport([try .golden("pull-response")])
        let report = try await makeEngine(store, transport).sync()

        let vehicle = try #require(await store.vehicle(IDs.vehicle))
        #expect(vehicle.make == "Toyota")
        #expect(await store.version(of: vehicleRef) == 41)
        let stored = try #require(await store.stored(IDs.record))
        #expect(stored.record.serviceType == .oilChange)
        #expect(stored.record.laborCost == Money(kopecks: 350_000))
        #expect(await store.version(of: recordRef) == 42)
        #expect(await store.version(of: ref(.serviceRecord, IDs.deletedRecord)) == 43)
        #expect(await store.stored(IDs.deletedRecord) == nil)
        #expect(await store.cursor() == "43")
        #expect(report.pulled == 3)
        #expect(await transport.requests.count == 1)
    }

    // 3
    @Test(arguments: [
        ("2026-10-07T10:00:00.000Z", "2026-10-07T11:00:00.000Z"),
        ("2026-10-07T10:00:00.000Z", "2026-10-07T10:00:00.000Z"),
    ])
    func serverWinsWhenNotOlder(local: String, server: String) async throws {
        let store = InMemorySyncStore()
        await store.setVersion(5, of: vehicleRef)
        await store.upsertLocal(.vehicle(makeVehicle()), modifiedAt: date(local), changeID: IDs.changeA)
        let remote = makeVehicle(make: "Lexus", mileageKm: 90_000)
        let transport = FakeHTTPTransport([
            try .json(
                PushResponse(results: [
                    conflict(.versionMismatch, serverChange(9, server, .vehicle(remote)), id: IDs.changeA)
                ])),
            try .json(emptyPull(cursor: "9")),
        ])
        let report = try await makeEngine(store, transport).sync()

        #expect(await store.vehicle(IDs.vehicle) == remote)
        #expect(await store.version(of: vehicleRef) == 9)
        #expect(await store.pendingChanges().isEmpty)
        #expect(await transport.requests.count == 2)
        #expect(report.conflictsResolved == 1)
    }

    // 4
    @Test func retryAfterTransportFailureSendsSameBody() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T09:30:00.000Z"), changeID: IDs.changeA)
        let transport = FakeHTTPTransport([.fail(URLError(.notConnectedToInternet))])
        let engine = makeEngine(store, transport)

        await #expect(throws: URLError.self) { try await engine.sync() }
        #expect(await store.pendingChanges().count == 1)

        await transport.enqueue(
            try .json(PushResponse(results: [PushResult(changeID: IDs.changeA, outcome: .applied(version: 3))])))
        await transport.enqueue(try .json(emptyPull(cursor: "3")))
        _ = try await engine.sync()

        let requests = await transport.requests
        #expect(requests[0].body == requests[1].body)
        #expect(requests[0].body != nil)
        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.version(of: vehicleRef) == 3)
    }

    @Test(arguments: [ConflictReason.versionMismatch, .alreadyExists])
    func conflictWithOwnContentCountsAsApplied(reason: ConflictReason) async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T09:30:00.000Z"), changeID: IDs.changeA)
        let own = try #require(await store.pendingChanges().first)
        let current = ServerChange(
            version: 12, modifiedAt: date("2026-10-07T09:30:00.000Z"), operation: own.pushChange.operation)
        let transport = FakeHTTPTransport([
            try .json(PushResponse(results: [conflict(reason, current, id: IDs.changeA)])),
            try .json(emptyPull(cursor: "12")),
        ])
        _ = try await makeEngine(store, transport).sync()

        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.version(of: vehicleRef) == 12)
        #expect(await transport.requests.count == 2)
    }

    // 5
    @Test func deletedConflictRemovesLocalRecord() async throws {
        let store = InMemorySyncStore()
        await store.setVersion(3, of: recordRef)
        await store.upsertLocal(
            .serviceRecord(makeRecord(), RecordSyncExtras()), modifiedAt: date("2026-10-07T11:00:00.000Z"),
            changeID: IDs.changeA)
        let transport = FakeHTTPTransport([
            try .json(
                PushResponse(results: [
                    conflict(.deleted, tombstone(20, "2026-10-07T09:00:00.000Z", recordRef), id: IDs.changeA)
                ])),
            try .json(emptyPull(cursor: "20")),
        ])
        _ = try await makeEngine(store, transport).sync()

        #expect(await store.stored(IDs.record) == nil)
        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.version(of: recordRef) == 20)
    }

    // 6
    @Test func vehicleNotFoundDeletesRecordLocally() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .serviceRecord(makeRecord(), RecordSyncExtras()), modifiedAt: date("2026-10-07T11:00:00.000Z"),
            changeID: IDs.changeA)
        let error = APIError(code: .vehicleNotFound, message: "no vehicle")
        let transport = FakeHTTPTransport([
            try .json(PushResponse(results: [PushResult(changeID: IDs.changeA, outcome: .rejected(error))])),
            try .json(emptyPull(cursor: "1")),
        ])
        let report = try await makeEngine(store, transport).sync()

        #expect(await store.stored(IDs.record) == nil)
        #expect(await store.pendingChanges().isEmpty)
        #expect(report.rejected.count == 1)
    }

    @Test func validationFailureKeepsLocalDataButLeavesQueue() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T11:00:00.000Z"), changeID: IDs.changeA)
        let error = APIError(code: .validationFailed, message: "bad")
        let transport = FakeHTTPTransport([
            try .json(PushResponse(results: [PushResult(changeID: IDs.changeA, outcome: .rejected(error))])),
            try .json(emptyPull(cursor: "1")),
        ])
        let report = try await makeEngine(store, transport).sync()

        #expect(await store.vehicle(IDs.vehicle) != nil)
        #expect(await store.pendingChanges().isEmpty)
        #expect(report.rejected.count == 1)
    }

    // 7
    @Test func pullPaginatesAndResumesAfterInterruption() async throws {
        let store = InMemorySyncStore()
        let page1 = PullResponse(
            changes: [
                serverChange(1, "2026-10-07T09:00:00.000Z", .vehicle(makeVehicle())),
                serverChange(2, "2026-10-07T09:01:00.000Z", .serviceRecord(makeRecord(), RecordSyncExtras())),
            ], cursor: "2", hasMore: true)
        let page2 = PullResponse(
            changes: [serverChange(3, "2026-10-07T09:02:00.000Z", .vehicle(makeVehicle(make: "Lexus")))],
            cursor: "3", hasMore: false)
        let transport = FakeHTTPTransport([try .json(page1), .fail(URLError(.timedOut))])
        let engine = makeEngine(store, transport)

        await #expect(throws: URLError.self) { try await engine.sync() }
        #expect(await store.cursor() == "2")
        #expect(await store.stored(IDs.record) != nil)

        await transport.enqueue(try .json(page2))
        _ = try await engine.sync()
        let requests = await transport.requests
        #expect(requests[1].query.contains(URLQueryItem(name: "after", value: "2")))
        #expect(requests[2].query.contains(URLQueryItem(name: "after", value: "2")))
        #expect(await store.cursor() == "3")
        #expect(await store.vehicle(IDs.vehicle)?.make == "Lexus")
    }

    // 8
    @Test func unknownConflictReasonIsResolvedFromCurrent() async throws {
        let store = InMemorySyncStore()
        await store.setVersion(5, of: vehicleRef)
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        let remote = makeVehicle(make: "Lexus")
        let transport = FakeHTTPTransport([
            try .json(
                PushResponse(results: [
                    conflict(
                        .unknown("futureReason"), serverChange(9, "2026-10-07T11:00:00.000Z", .vehicle(remote)),
                        id: IDs.changeA)
                ])),
            try .json(emptyPull(cursor: "9")),
        ])
        _ = try await makeEngine(store, transport).sync()
        #expect(await store.vehicle(IDs.vehicle) == remote)
        #expect(await store.version(of: vehicleRef) == 9)
    }

    // 9
    @Test func unknownServiceTypeSurvivesLocalEdit() async throws {
        var dto = ServiceRecordDTO(makeRecord(), extras: RecordSyncExtras())
        dto.serviceType = "battery"
        let store = InMemorySyncStore()
        let pull = PullResponse(
            changes: [
                serverChange(1, "2026-10-07T09:00:00.000Z", .vehicle(makeVehicle())),
                ServerChange(
                    version: 2, modifiedAt: date("2026-10-07T09:01:00.000Z"), operation: .upsert(.serviceRecord(dto))),
            ], cursor: "2", hasMore: false)
        let transport = FakeHTTPTransport([try .json(pull)])
        let engine = makeEngine(store, transport)
        _ = try await engine.sync()

        let stored = try #require(await store.stored(IDs.record))
        #expect(stored.record.serviceType == .other("battery"))
        #expect(stored.extras.rawServiceType == "battery")

        var edited = stored.record
        try edited.updateLaborCost(Money(kopecks: 500_000))
        await store.upsertLocal(
            .serviceRecord(edited, stored.extras), modifiedAt: date("2026-10-07T12:00:00.000Z"),
            changeID: IDs.changeA)
        await transport.enqueue(
            try .json(PushResponse(results: [PushResult(changeID: IDs.changeA, outcome: .applied(version: 3))])))
        await transport.enqueue(try .json(emptyPull(cursor: "3")))
        _ = try await engine.sync()

        let pushed = try decodePush(await transport.requests[1])
        guard case .upsert(.serviceRecord(let sent)) = pushed.changes[0].operation else {
            Issue.record("expected a record upsert")
            return
        }
        #expect(sent.serviceType == "battery")
        #expect(sent.laborCostKopecks == 500_000)
    }

    // 10
    @Test func unauthorizedSurfacesAsAPIError() async throws {
        let store = InMemorySyncStore()
        let body = APIErrorResponse(error: APIError(code: .unauthorized, message: "bad token"))
        let transport = FakeHTTPTransport([try .json(body, status: 401)])
        do {
            _ = try await makeEngine(store, transport).sync()
            Issue.record("expected an error")
        } catch SyncError.api(let status, let error) {
            #expect(status == 401)
            #expect(error.code == .unauthorized)
        }
    }

    @Test func undecodableErrorBodyIsHTTPError() async throws {
        let transport = FakeHTTPTransport([.respond(502, Data("<html>".utf8))])
        do {
            _ = try await makeEngine(InMemorySyncStore(), transport).sync()
            Issue.record("expected an error")
        } catch SyncError.http(let status) {
            #expect(status == 502)
        }
    }

    @Test func cursorExpiredTriggersFullPull() async throws {
        let store = InMemorySyncStore()
        await store.setCursor("5")
        let expired = APIErrorResponse(error: APIError(code: .cursorExpired, message: "expired"))
        let transport = FakeHTTPTransport([try .json(expired, status: 410), try .golden("pull-response")])
        _ = try await makeEngine(store, transport).sync()

        let requests = await transport.requests
        #expect(requests[0].query.contains(URLQueryItem(name: "after", value: "5")))
        #expect(requests[1].query.contains { $0.name == "after" } == false)
        #expect(await store.cursor() == "43")
        #expect(await store.vehicle(IDs.vehicle) != nil)
    }

    @Test func resultCountMismatchIsMalformed() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T09:30:00.000Z"), changeID: IDs.changeA)
        let transport = FakeHTTPTransport([try .json(PushResponse(results: []))])
        do {
            _ = try await makeEngine(store, transport).sync()
            Issue.record("expected an error")
        } catch SyncError.malformedResponse {
            #expect(await store.pendingChanges().count == 1)
        }
    }

    @Test func invalidRemoteChangeIsSkippedNotFatal() async throws {
        let store = InMemorySyncStore()
        let bad = VehicleDTO(id: IDs.vehicle, kind: "spaceship", make: "A", model: "B", year: 2000, mileageKm: 1)
        let pull = PullResponse(
            changes: [
                ServerChange(
                    version: 1, modifiedAt: date("2026-10-07T09:00:00.000Z"), operation: .upsert(.vehicle(bad)))
            ], cursor: "1", hasMore: false)
        let report = try await makeEngine(store, FakeHTTPTransport([try .json(pull)])).sync()
        #expect(report.skipped.count == 1)
        #expect(report.pulled == 0)
        #expect(await store.cursor() == "1")
    }
}

@Suite struct SyncEngineSafetyTests {
    @Test func recordOfRejectedVehicleIsNotDeleted() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T09:00:00.000Z"), changeID: IDs.changeA)
        await store.upsertLocal(
            .serviceRecord(makeRecord(), RecordSyncExtras()), modifiedAt: date("2026-10-07T09:01:00.000Z"),
            changeID: IDs.changeB)
        let transport = FakeHTTPTransport([
            try .json(
                PushResponse(results: [
                    PushResult(
                        changeID: IDs.changeA, outcome: .rejected(APIError(code: .validationFailed, message: "bad"))),
                    PushResult(
                        changeID: IDs.changeB, outcome: .rejected(APIError(code: .vehicleNotFound, message: "none"))),
                ])),
            try .json(emptyPull(cursor: "1")),
        ])
        _ = try await makeEngine(store, transport).sync()
        #expect(await store.stored(IDs.record) != nil)
        #expect(await store.pendingChanges().isEmpty)
    }

    @Test func concurrentSyncsShareOneRun() async throws {
        let store = InMemorySyncStore()
        let transport = FakeHTTPTransport([try .json(emptyPull(cursor: "1")), try .json(emptyPull(cursor: "1"))])
        let engine = makeEngine(store, transport)
        async let a = engine.sync()
        async let b = engine.sync()
        _ = try await (a, b)
        #expect(await transport.requests.count == 1)
    }
}

@Suite struct SyncEngineEdgeCaseTests {
    @Test func modifiedAtIsRoundedToMilliseconds() {
        let raw = date("2026-10-07T10:00:00.000Z").addingTimeInterval(0.0006)
        let change = PendingChange(
            changeID: IDs.changeA, baseVersion: nil, modifiedAt: raw, operation: .delete(vehicleRef))
        #expect(abs(change.modifiedAt.timeIntervalSince(date("2026-10-07T10:00:00.001Z"))) < 0.0001)
    }

    @Test func ownEditReturnedFromPullSkipsLWW() async throws {
        let store = InMemorySyncStore()
        let rawTime = date("2026-10-07T10:00:00.000Z").addingTimeInterval(0.0004)
        // Sub-millisecond local time: unrounded, it would look newer than the server's copy of the same edit.
        let back = serverChange(8, "2026-10-07T10:00:00.000Z", .vehicle(makeVehicle()))
        let transport = FakeHTTPTransport([
            .before(
                { await store.upsertLocal(.vehicle(makeVehicle()), modifiedAt: rawTime, changeID: IDs.changeA) },
                try .json(PullResponse(changes: [back], cursor: "8", hasMore: false)))
        ])
        let report = try await makeEngine(store, transport).sync()
        #expect(report.conflictsResolved == 0)
        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.version(of: vehicleRef) == 8)
    }

    @Test func unmappableCurrentDiscardsEditAndReports() async throws {
        let store = InMemorySyncStore()
        await store.setVersion(5, of: vehicleRef)
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        let bad = VehicleDTO(id: IDs.vehicle, kind: "spaceship", make: "A", model: "B", year: 2000, mileageKm: 1)
        let current = ServerChange(
            version: 9, modifiedAt: date("2026-10-07T11:00:00.000Z"), operation: .upsert(.vehicle(bad)))
        let transport = FakeHTTPTransport([
            try .json(PushResponse(results: [conflict(.versionMismatch, current, id: IDs.changeA)])),
            try .json(emptyPull(cursor: "9")),
        ])
        let report = try await makeEngine(store, transport).sync()
        #expect(await store.pendingChanges().isEmpty)
        #expect(report.skipped.count == 1)
        #expect(await transport.requests.count == 2)
    }

    @Test func pushRoundsAreCappedAtThree() async throws {
        let store = InMemorySyncStore()
        await store.setVersion(5, of: vehicleRef)
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T12:00:00.000Z"), changeID: IDs.changeA)
        var steps: [FakeHTTPTransport.Step] = []
        for version in Int64(6)...8 {
            let current = serverChange(version, "2026-10-07T11:00:00.000Z", .vehicle(makeVehicle(make: "Lexus")))
            steps.append(try .json(PushResponse(results: [conflict(.versionMismatch, current, id: IDs.changeA)])))
        }
        steps.append(try .json(emptyPull(cursor: "8")))
        let transport = FakeHTTPTransport(steps)
        let report = try await makeEngine(store, transport).sync()

        #expect(await transport.requests.count == 4)
        #expect(report.stillPending.count == 1)
        #expect(report.stillPending.first?.baseVersion == 8)
        #expect(await store.vehicle(IDs.vehicle) == makeVehicle())
    }

    @Test func newerLocalEditIsRebasedDuringPull() async throws {
        let store = InMemorySyncStore()
        let remote = serverChange(9, "2026-10-07T11:00:00.000Z", .vehicle(makeVehicle(make: "Lexus")))
        let transport = FakeHTTPTransport([
            .before(
                {
                    await store.upsertLocal(
                        .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T12:00:00.000Z"),
                        changeID: IDs.changeA)
                }, try .json(PullResponse(changes: [remote], cursor: "9", hasMore: false)))
        ])
        let report = try await makeEngine(store, transport).sync()
        let pending = try #require(await store.pendingChanges().first)
        #expect(pending.baseVersion == 9)
        #expect(await store.vehicle(IDs.vehicle) == makeVehicle())
        #expect(report.conflictsResolved == 1)
    }

    @Test func pulledTombstoneBeatsLocalEdit() async throws {
        let store = InMemorySyncStore()
        let transport = FakeHTTPTransport([
            .before(
                {
                    await store.upsertLocal(
                        .serviceRecord(makeRecord(), RecordSyncExtras()),
                        modifiedAt: date("2026-10-07T12:00:00.000Z"), changeID: IDs.changeA)
                },
                try .json(
                    PullResponse(
                        changes: [tombstone(10, "2026-10-07T09:00:00.000Z", recordRef)], cursor: "10", hasMore: false)))
        ])
        _ = try await makeEngine(store, transport).sync()
        #expect(await store.stored(IDs.record) == nil)
        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.version(of: recordRef) == 10)
    }

    @Test func localDeleteBeatsPulledUpsert() async throws {
        let store = InMemorySyncStore()
        let remote = serverChange(
            10, "2026-10-07T13:00:00.000Z", .serviceRecord(makeRecord(), RecordSyncExtras()))
        let transport = FakeHTTPTransport([
            .before(
                {
                    await store.deleteLocal(
                        recordRef, modifiedAt: date("2026-10-07T12:00:00.000Z"), changeID: IDs.changeA)
                }, try .json(PullResponse(changes: [remote], cursor: "10", hasMore: false)))
        ])
        _ = try await makeEngine(store, transport).sync()
        let pending = try #require(await store.pendingChanges().first)
        #expect(pending.operation.isDelete)
        #expect(pending.baseVersion == 10)
        #expect(await store.stored(IDs.record) == nil)
    }

    @Test func largeQueueIsPushedInBatchesOfAtMostHundred() async throws {
        let store = InMemorySyncStore()
        for index in 0..<250 {
            await store.upsertLocal(
                .vehicle(makeVehicle(id: UUID(), make: "Make \(index)")),
                modifiedAt: date("2026-10-07T09:00:00.000Z"), changeID: UUID())
        }
        let pending = await store.pendingChanges()
        var steps: [FakeHTTPTransport.Step] = []
        for start in stride(from: 0, to: pending.count, by: 100) {
            let results = pending[start..<min(start + 100, pending.count)].enumerated().map { offset, change in
                PushResult(changeID: change.changeID, outcome: .applied(version: Int64(start + offset + 1)))
            }
            steps.append(try .json(PushResponse(results: results)))
        }
        steps.append(try .json(emptyPull(cursor: "250")))
        let transport = FakeHTTPTransport(steps)
        let report = try await makeEngine(store, transport).sync()

        let requests = await transport.requests
        #expect(try requests.dropLast().map { try decodePush($0).changes.count } == [100, 100, 50])
        #expect(report.pushed == 250)
        #expect(await store.pendingChanges().isEmpty)
    }

    @Test func cursorIsPercentEncoded() async throws {
        let store = InMemorySyncStore()
        await store.setCursor("a+b&c")
        let transport = FakeHTTPTransport([try .json(emptyPull(cursor: "a+b&c"))])
        _ = try await makeEngine(store, transport).sync()
        let item = try #require(await transport.requests[0].query.first { $0.name == "after" })
        #expect(item.value == "a%2Bb%26c")
    }
}
