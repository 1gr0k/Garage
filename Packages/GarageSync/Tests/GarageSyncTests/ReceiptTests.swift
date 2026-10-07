import Foundation
import GarageAPI
import GarageCore
import Testing

@testable import GarageSync

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private let shaA = String(repeating: "a", count: 64)
private let shaB = String(repeating: "b", count: 64)
private let recordB = uuid("44444444-4444-4444-8444-444444444444")

private func recordWithReceipt(id: UUID = IDs.record, sha: String) -> SyncEntity {
    .serviceRecord(
        makeRecord(id: id), RecordSyncExtras(receipt: ReceiptRefDTO(sha256: sha, byteCount: 3)))
}

private func applied(_ id: UUID, _ version: Int64) -> PushResult {
    PushResult(changeID: id, outcome: .applied(version: version))
}

private func errorBody(_ code: APIErrorCode) throws -> FakeHTTPTransport.Step {
    .respond(
        code.httpStatus ?? 400,
        try APICoding.makeEncoder().encode(APIErrorResponse(error: APIError(code: code, message: "x"))))
}

@Suite struct ReceiptTests {
    @Test func registerDeviceSendsSecretWithoutTokenAndParsesResponse() async throws {
        let transport = FakeHTTPTransport([try .golden("register-device-response", status: 201)])
        let response = try await SyncAPIClient.registerDevice(
            transport: transport, setupSecret: "correct-horse-battery-staple", deviceName: "iPhone Андрея")

        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/devices")
        #expect(request.headers["Authorization"] == nil)
        #expect(
            try JSONValue(data: #require(request.body))
                == JSONValue(data: GoldenExamples.data("register-device-request")))
        #expect(response.deviceID == uuid("66666666-6666-4666-8666-666666666666"))
        #expect(response.token == "q83vEjRZk1T7mP0cX2wYb9LdAaNfU5hGsKiOtVeJr4I")
    }

    @Test func registerDeviceWithWrongSecretThrowsInvalidSetupSecret() async throws {
        let transport = FakeHTTPTransport([try errorBody(.invalidSetupSecret)])
        do {
            _ = try await SyncAPIClient.registerDevice(transport: transport, setupSecret: "no", deviceName: "x")
            Issue.record("expected an error")
        } catch SyncError.api(let status, let error) {
            #expect(status == 401)
            #expect(error.code == .invalidSetupSecret)
        }
    }

    @Test func receiptIsUploadedBeforeTheChangesAreSent() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            recordWithReceipt(sha: shaA), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        let blobs = InMemoryBlobStore(blobs: [shaA: Data([1, 2, 3])])
        let transport = FakeHTTPTransport([
            .respond(201, Data()),
            try .json(PushResponse(results: [applied(IDs.changeA, 5)])),
            try .json(emptyPull(cursor: "5")),
        ])
        let report = try await makeEngine(store, transport, receipts: blobs).sync()

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["PUT", "POST", "GET"])
        #expect(requests[0].path == "/v1/receipts/\(shaA)")
        #expect(requests[0].headers["Content-Type"] == "image/jpeg")
        #expect(requests[0].headers["Authorization"] == "Bearer test-token")
        #expect(requests[0].body == Data([1, 2, 3]))
        #expect(report.pushed == 1)
        #expect(report.receiptFailures.isEmpty)
    }

    @Test func failedUploadKeepsOnlyThatEditQueued() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            recordWithReceipt(sha: shaA), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T10:01:00.000Z"), changeID: IDs.changeB)
        let blobs = InMemoryBlobStore(blobs: [shaA: Data([1, 2, 3])])
        let transport = FakeHTTPTransport([
            try errorBody(.payloadTooLarge),
            try .json(PushResponse(results: [applied(IDs.changeB, 3)])),
            try .json(emptyPull(cursor: "3")),
        ])
        let report = try await makeEngine(store, transport, receipts: blobs).sync()

        let requests = await transport.requests
        #expect(try decodePush(requests[1]).changes.map(\.changeID) == [IDs.changeB])
        #expect(report.pushed == 1)
        #expect(report.stillPending.map(\.changeID) == [IDs.changeA])
        #expect(report.receiptFailures.map(\.sha256) == [shaA])
        #expect(await store.pendingChanges().map(\.changeID) == [IDs.changeA])
    }

    /// П. 2 этапа 10: upsert записи стоял в очереди до sync, push придержал его (чек не загрузился),
    /// pull приносит tombstone машины — upsert записи снимается каскадом `apply`, а не push'ем.
    @Test func vehicleTombstoneDropsRecordUpsertHeldByReceiptFailure() async throws {
        let store = InMemorySyncStore()
        await store.storeSynced(.vehicle(makeVehicle()), version: 1)
        await store.upsertLocal(
            recordWithReceipt(sha: shaA), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        let blobs = InMemoryBlobStore(blobs: [shaA: Data([1, 2, 3])])
        let vehicleTombstone = ServerChange(
            version: 5, modifiedAt: date("2026-10-07T11:00:00.000Z"), operation: .delete(.vehicle, id: IDs.vehicle))
        let transport = FakeHTTPTransport([
            try errorBody(.payloadTooLarge),
            try .json(PullResponse(changes: [vehicleTombstone], cursor: "5", hasMore: false)),
        ])
        let report = try await makeEngine(store, transport, receipts: blobs).sync()

        // Push не отправлялся: единственное изменение придержано, дальше сразу pull.
        #expect(await transport.requests.map(\.method) == ["PUT", "GET"])
        #expect(report.pulled == 1)
        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.stored(IDs.record) == nil)
        #expect(await store.vehicle(IDs.vehicle) == nil)
    }

    @Test func transportErrorDuringUploadPropagates() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            recordWithReceipt(sha: shaA), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        let blobs = InMemoryBlobStore(blobs: [shaA: Data([1])])
        let transport = FakeHTTPTransport([.fail(URLError(.notConnectedToInternet))])
        await #expect(throws: URLError.self) {
            _ = try await makeEngine(store, transport, receipts: blobs).sync()
        }
        #expect(await store.pendingChanges().count == 1)
    }

    @Test func sameHashIsUploadedOnce() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            recordWithReceipt(sha: shaA), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        await store.upsertLocal(
            .serviceRecord(
                makeRecord(id: recordB), RecordSyncExtras(receipt: ReceiptRefDTO(sha256: shaA, byteCount: 3))),
            modifiedAt: date("2026-10-07T10:01:00.000Z"), changeID: IDs.changeB)
        let blobs = InMemoryBlobStore(blobs: [shaA: Data([1, 2, 3])])
        let transport = FakeHTTPTransport([
            .respond(200, Data()),
            try .json(PushResponse(results: [applied(IDs.changeA, 1), applied(IDs.changeB, 2)])),
            try .json(emptyPull(cursor: "2")),
        ])
        _ = try await makeEngine(store, transport, receipts: blobs).sync()

        #expect(await transport.requests.map(\.method) == ["PUT", "POST", "GET"])
    }

    @Test func missingBlobLocallySkipsUploadButPushesTheRecord() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            recordWithReceipt(sha: shaA), modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        let transport = FakeHTTPTransport([
            try .json(PushResponse(results: [applied(IDs.changeA, 1)])),
            try .json(emptyPull(cursor: "1")),
        ])
        let report = try await makeEngine(store, transport, receipts: InMemoryBlobStore()).sync()

        #expect(await transport.requests.map(\.method) == ["POST", "GET"])
        #expect(report.pushed == 1)
    }

    @Test func receiptsAreDownloadedAfterPull() async throws {
        let store = InMemorySyncStore()
        let ref = ReceiptRefDTO(sha256: shaB, byteCount: 2)
        let blobs = InMemoryBlobStore(missing: [ref])
        let transport = FakeHTTPTransport([
            try .json(emptyPull(cursor: "1")),
            .respond(200, Data([9, 9])),
        ])
        let report = try await makeEngine(store, transport, receipts: blobs).sync()

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "GET"])
        #expect(requests[1].path == "/v1/receipts/\(shaB)")
        #expect(await blobs.stored[shaB] == Data([9, 9]))
        #expect(report.receiptFailures.isEmpty)
    }

    @Test func failedDownloadIsReportedAndDoesNotBreakSync() async throws {
        let store = InMemorySyncStore()
        let blobs = InMemoryBlobStore(missing: [
            ReceiptRefDTO(sha256: shaA, byteCount: 1), ReceiptRefDTO(sha256: shaB, byteCount: 1),
        ])
        let transport = FakeHTTPTransport([
            try .json(emptyPull(cursor: "1")),
            .fail(URLError(.timedOut)),
            .respond(200, Data([7])),
        ])
        let report = try await makeEngine(store, transport, receipts: blobs).sync()

        #expect(report.receiptFailures.map(\.sha256) == [shaA])
        #expect(await blobs.stored[shaB] == Data([7]))
        #expect(await store.cursor() == "1")
    }

    @Test func storeFailureIsReportedAndDoesNotBreakSync() async throws {
        let store = InMemorySyncStore()
        let blobs = InMemoryBlobStore(missing: [ReceiptRefDTO(sha256: shaA, byteCount: 1)])
        await blobs.setFailStoring(true)
        let transport = FakeHTTPTransport([try .json(emptyPull(cursor: "1")), .respond(200, Data([7]))])
        let report = try await makeEngine(store, transport, receipts: blobs).sync()

        #expect(report.receiptFailures.map(\.sha256) == [shaA])
    }
}
