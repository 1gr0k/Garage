import Fluent
import Foundation
import GarageAPI
import Testing
import Vapor
import VaporTesting

@testable import App

// MARK: - Pull

@Test func emptyPullReturnsCursorEqualToAfter() async throws {
    try await withTestApp { _, client in
        let full = try await client.pull()
        #expect(full.changes.isEmpty)
        #expect(full.cursor == "0")
        #expect(full.hasMore == false)

        let after = try await client.pull(after: "7")
        #expect(after.changes.isEmpty)
        #expect(after.cursor == "7")
    }
}

@Test func fullPullIncludesTombstones() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let record = Fixture.record(vehicleID: vehicle.id)
        let doomed = Fixture.record(vehicleID: vehicle.id)
        _ = try await client.push([
            Fixture.upsert(vehicle), Fixture.upsert(record), Fixture.upsert(doomed),
        ])
        _ = try await client.push(Fixture.delete(.serviceRecord, doomed.id))

        let pull = try await client.pull()
        #expect(pull.changes.map(\.version) == [1, 2, 4])
        #expect(pull.cursor == "4")
        #expect(pull.changes[0].upsertedPayload == .vehicle(vehicle))
        #expect(pull.changes[1].upsertedPayload == .serviceRecord(record))
        #expect(pull.changes[2].operation == .delete(.serviceRecord, id: doomed.id))
    }
}

@Test func pullPaginatesWithCursorAndHasMore() async throws {
    try await withTestApp { _, client in
        _ = try await client.push((0..<5).map { _ in Fixture.upsert(Fixture.vehicle()) })

        let first = try await client.pull(limit: 2)
        #expect(first.changes.map(\.version) == [1, 2])
        #expect(first.cursor == "2")
        #expect(first.hasMore)

        let second = try await client.pull(after: first.cursor, limit: 2)
        #expect(second.changes.map(\.version) == [3, 4])
        #expect(second.cursor == "4")
        #expect(second.hasMore)

        let third = try await client.pull(after: second.cursor, limit: 2)
        #expect(third.changes.map(\.version) == [5])
        #expect(third.cursor == "5")
        #expect(third.hasMore == false)
    }
}

@Test(arguments: [
    ("after", "abc"), ("after", "-1"), ("after", "1.5"), ("after", "99999999999999999999"),
    ("limit", "0"), ("limit", "501"), ("limit", "-3"), ("limit", "ten"),
])
func invalidPullParametersAreRejected(field: String, value: String) async throws {
    try await withTestApp { _, client in
        let response = try await client.raw(.GET, "\(APIPath.changes)?\(field)=\(value)")
        #expect(response.status == .badRequest)
        let error = try client.apiError(response)
        #expect(error.code == .malformedRequest)
        #expect(error.details?["field"] == field)
    }
}

@Test func pullPreservesModifiedAtMilliseconds() async throws {
    try await withTestApp { _, client in
        // …20.123Z must come back with the same milliseconds (the double 1790000000.123 sits just below it).
        let instant = Date(timeIntervalSince1970: 1_790_000_000.123)
        let vehicle = Fixture.vehicle()
        let record = ServiceRecordDTO(
            id: UUID(), vehicleID: vehicle.id, date: instant, mileageKm: 1, serviceType: "repair",
            laborCostKopecks: 0, notes: "", parts: [])
        _ = try await client.push([Fixture.upsert(vehicle, at: instant), Fixture.upsert(record, at: instant)])

        let response = try await client.pullRaw()
        let text = String(decoding: response.body.readableBytesView, as: UTF8.self)
        // 2 × modifiedAt + record date
        #expect(text.components(separatedBy: "2026-09-21T14:13:20.123Z").count - 1 == 3)
    }
}

// MARK: - Push

@Test func pushCreatesEntitiesWithIncreasingVersions() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let results = try await client.push([
            Fixture.upsert(vehicle), Fixture.upsert(Fixture.record(vehicleID: vehicle.id)),
        ])
        #expect(try results.map { try $0.appliedVersion() } == [1, 2])
    }
}

@Test func updateWithCurrentBaseVersionIsApplied() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let created = try await client.push(Fixture.upsert(vehicle)).appliedVersion()
        let updated = Fixture.vehicle(id: vehicle.id, mileageKm: 2000)
        let version = try await client.push(Fixture.upsert(updated, base: created)).appliedVersion()
        #expect(version == created + 1)
        #expect(try await client.pull().changes.map(\.version) == [version])
    }
}

@Test func editsFromTwoDevicesConflictOnVersionMismatch() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let record = Fixture.record(vehicleID: vehicle.id, notes: "original")
        _ = try await client.push(Fixture.upsert(vehicle))
        let base = try await client.push(Fixture.upsert(record)).appliedVersion()

        let deviceA = Fixture.record(id: record.id, vehicleID: vehicle.id, notes: "from A")
        let deviceB = Fixture.record(id: record.id, vehicleID: vehicle.id, notes: "from B")
        let versionA = try await client.push(Fixture.upsert(deviceA, base: base)).appliedVersion()

        let (reason, current) = try await client.push(Fixture.upsert(deviceB, base: base)).conflict()
        #expect(reason == .versionMismatch)
        #expect(current.version == versionA)
        #expect(current.upsertedPayload == .serviceRecord(deviceA))
        // The conflicting change was not stored.
        #expect(try await client.pull(after: String(versionA)).changes.isEmpty)
    }
}

@Test func createOverExistingEntityConflictsWithAlreadyExists() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let version = try await client.push(Fixture.upsert(vehicle)).appliedVersion()
        let (reason, current) = try await client.push(Fixture.upsert(Fixture.vehicle(id: vehicle.id, year: 1999)))
            .conflict()
        #expect(reason == .alreadyExists)
        #expect(current.version == version)
        #expect(current.upsertedPayload == .vehicle(vehicle))
    }
}

@Test func repeatedPushWithSameChangeIDReturnsSameVersion() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let create = Fixture.upsert(vehicle)
        let first = try await client.push(create)
        let second = try await client.push(create)
        #expect(first == second)

        let update = Fixture.upsert(Fixture.vehicle(id: vehicle.id, mileageKm: 5), base: try first.appliedVersion())
        let updateFirst = try await client.push(update)
        let updateSecond = try await client.push(update)
        #expect(updateFirst == updateSecond)
        // No extra versions were allocated by the repeats.
        #expect(try await client.pull().cursor == String(try updateFirst.appliedVersion()))
    }
}

@Test func upsertWithBaseVersionForUnknownIDCreates() async throws {
    try await withTestApp { _, client in
        let version = try await client.push(Fixture.upsert(Fixture.vehicle(), base: 42)).appliedVersion()
        #expect(version == 1)
    }
}

@Test func batchOfMoreThanOneHundredItemsIsRejected() async throws {
    try await withTestApp { _, client in
        let changes = (0..<101).map { _ in Fixture.upsert(Fixture.vehicle()) }
        let response = try await client.json(.POST, APIPath.changes, PushRequest(changes: changes))
        #expect(response.status == .badRequest)
        #expect(try client.apiError(response).code == .malformedRequest)
        #expect(try await client.pull().changes.isEmpty)

        let full = try await client.push(Array(changes.prefix(100)))
        #expect(full.count == 100)
    }
}

@Test func malformedPushBodyIsRejected() async throws {
    try await withTestApp { _, client in
        var headers = HTTPHeaders()
        headers.contentType = .json
        let response = try await client.raw(.POST, APIPath.changes, headers: headers, body: ByteBuffer(string: "{}"))
        #expect(response.status == .badRequest)
        #expect(try client.apiError(response).code == .malformedRequest)
    }
}

@Test func rejectedItemDoesNotBlockOthersOrConsumeVersions() async throws {
    try await withTestApp { _, client in
        let results = try await client.push([
            Fixture.upsert(Fixture.vehicle(mileageKm: -1)),
            Fixture.upsert(Fixture.vehicle()),
            Fixture.upsert(Fixture.vehicle()),
        ])
        #expect(try results[0].rejection().code == .validationFailed)
        #expect(try results[1].appliedVersion() == 1)
        #expect(try results[2].appliedVersion() == 2)
    }
}

@Test func contentIsValidatedWithDomainRules() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        _ = try await client.push(Fixture.upsert(vehicle))
        let part = { (quantity: Int, name: String, price: Int) in
            PartDTO(id: UUID(), name: name, unitPriceKopecks: price, quantity: quantity)
        }
        let cases: [(PushChange, String)] = [
            (Fixture.upsert(Fixture.vehicle(kind: "boat")), "unknownVehicleKind"),
            (Fixture.upsert(Fixture.vehicle(mileageKm: -5)), "negativeMileage"),
            (Fixture.upsert(Fixture.record(vehicleID: vehicle.id, serviceType: "teleport")), "unknownServiceType"),
            (
                Fixture.upsert(Fixture.record(vehicleID: vehicle.id, serviceType: "other:  ")),
                "emptyServiceTypeDescription"
            ),
            (Fixture.upsert(Fixture.record(vehicleID: vehicle.id, mileageKm: -1)), "negativeMileage"),
            (Fixture.upsert(Fixture.record(vehicleID: vehicle.id, mileageKm: 10_000_001)), "mileageTooLarge"),
            (
                Fixture.upsert(Fixture.record(vehicleID: vehicle.id, parts: [part(0, "Bolt", 100)])),
                "nonPositiveQuantity"
            ),
            (Fixture.upsert(Fixture.record(vehicleID: vehicle.id, parts: [part(1, " ", 100)])), "emptyPartName"),
            (Fixture.upsert(Fixture.record(vehicleID: vehicle.id, parts: [part(1, "Bolt", -1)])), "negativeAmount"),
        ]
        let results = try await client.push(cases.map(\.0))
        for (result, (_, expected)) in zip(results, cases) {
            let error = try result.rejection()
            #expect(error.code == .validationFailed)
            #expect(error.message.contains(expected), "\(error.message) should mention \(expected)")
        }
        // Valid custom service type and valid parts pass.
        let valid = Fixture.record(
            vehicleID: vehicle.id, serviceType: "other:Polish", parts: [part(2, "Bolt", 100)])
        _ = try await client.push(Fixture.upsert(valid)).appliedVersion()
    }
}

@Test func recordForMissingVehicleIsRejected() async throws {
    try await withTestApp { _, client in
        let missing = UUID()
        let error = try await client.push(Fixture.upsert(Fixture.record(vehicleID: missing))).rejection()
        #expect(error.code == .vehicleNotFound)
        #expect(error.message == "Vehicle \(missing.uuidString) does not exist")
    }
}

// MARK: - Deletion

@Test func deleteWinsOverEdit() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let version = try await client.push(Fixture.upsert(vehicle)).appliedVersion()
        let tombstone = try await client.push(Fixture.delete(.vehicle, vehicle.id)).appliedVersion()

        let edit = try await client.push(Fixture.upsert(Fixture.vehicle(id: vehicle.id, year: 1999), base: version))
            .conflict()
        #expect(edit.reason == .deleted)
        #expect(edit.current.version == tombstone)
        #expect(edit.current.operation == .delete(.vehicle, id: vehicle.id))

        let recreate = try await client.push(Fixture.upsert(vehicle)).conflict()
        #expect(recreate.reason == .deleted)
    }
}

@Test func deleteWithStaleBaseVersionIsApplied() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        _ = try await client.push(Fixture.upsert(vehicle))
        let version = try await client.push(Fixture.delete(.vehicle, vehicle.id, base: 999)).appliedVersion()
        #expect(version == 2)
    }
}

@Test func deletingUnknownIDWritesTombstoneThatBlocksResurrection() async throws {
    try await withTestApp { _, client in
        let id = UUID()
        let version = try await client.push(Fixture.delete(.serviceRecord, id, base: 7)).appliedVersion()
        #expect(version == 1)
        let pull = try await client.pull()
        #expect(pull.changes.map(\.operation) == [.delete(.serviceRecord, id: id)])

        let vehicle = Fixture.vehicle()
        _ = try await client.push(Fixture.upsert(vehicle))
        let blocked = try await client.push(Fixture.upsert(Fixture.record(id: id, vehicleID: vehicle.id))).conflict()
        #expect(blocked.reason == .deleted)
    }
}

@Test func repeatedDeleteReturnsExistingTombstoneVersion() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        _ = try await client.push(Fixture.upsert(vehicle))
        let first = try await client.push(Fixture.delete(.vehicle, vehicle.id)).appliedVersion()
        let again = try await client.push(Fixture.delete(.vehicle, vehicle.id)).appliedVersion()
        #expect(again == first)
        #expect(try await client.pull().cursor == String(first))
    }
}

@Test func deletingVehicleCascadesTombstonesToItsRecords() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let other = Fixture.vehicle()
        let records = (0..<2).map { _ in Fixture.record(vehicleID: vehicle.id) }
        let kept = Fixture.record(vehicleID: other.id)
        _ = try await client.push(
            [Fixture.upsert(vehicle), Fixture.upsert(other)] + records.map { Fixture.upsert($0) } + [
                Fixture.upsert(kept)
            ])
        // Versions 1…5 are taken.
        let deletion = Fixture.delete(.vehicle, vehicle.id, at: Fixture.date.addingTimeInterval(60))
        let version = try await client.push(deletion).appliedVersion()
        #expect(version == 6)

        let pull = try await client.pull(after: "5")
        #expect(pull.changes.map(\.version) == [6, 7, 8])
        #expect(pull.changes[0].operation == .delete(.vehicle, id: vehicle.id))
        let cascaded = Set(pull.changes.dropFirst().map(\.operation))
        #expect(cascaded == Set(records.map { .delete(.serviceRecord, id: $0.id) }))
        #expect(pull.changes.allSatisfy { $0.modifiedAt == Fixture.date.addingTimeInterval(60) })
        // The other vehicle's record is untouched.
        #expect(try await client.pull().changes.contains { $0.upsertedPayload == .serviceRecord(kept) })

        // New record for the deleted vehicle, and an upsert over a cascaded tombstone.
        let orphan = try await client.push(Fixture.upsert(Fixture.record(vehicleID: vehicle.id))).rejection()
        #expect(orphan.code == .vehicleNotFound)
        let resurrect = try await client.push(Fixture.upsert(records[0], base: 3)).conflict()
        #expect(resurrect.reason == .deleted)
    }
}

// MARK: - Receipts referenced from records

@Test func recordWithMissingReceiptBlobIsRejectedUntilUploaded() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        _ = try await client.push(Fixture.upsert(vehicle))
        let sha = Hashing.sha256Hex(Fixture.jpeg)
        let record = Fixture.record(
            vehicleID: vehicle.id, receipt: ReceiptRefDTO(sha256: sha, byteCount: Fixture.jpeg.count))

        let error = try await client.push(Fixture.upsert(record)).rejection()
        #expect(error.code == .receiptNotFound)

        let badHash = Fixture.record(vehicleID: vehicle.id, receipt: ReceiptRefDTO(sha256: "nothex", byteCount: 1))
        #expect(try await client.push(Fixture.upsert(badHash)).rejection().code == .receiptNotFound)

        #expect(try await client.putReceipt(Fixture.jpeg).status == .created)
        _ = try await client.push(Fixture.upsert(record)).appliedVersion()
    }
}

// MARK: - Monotonicity

@Test func concurrentPushesAllocateGaplessUniqueVersions() async throws {
    try await withTestApp { _, client in
        let workers = 10
        let perWorker = 10
        let versions = try await withThrowingTaskGroup(of: [Int64].self) { group in
            for _ in 0..<workers {
                group.addTask {
                    let results = try await client.push((0..<perWorker).map { _ in Fixture.upsert(Fixture.vehicle()) })
                    return try results.map { try $0.appliedVersion() }
                }
            }
            return try await group.reduce(into: []) { $0 += $1 }
        }
        #expect(versions.sorted() == Array(1...Int64(workers * perWorker)))

        let pull = try await client.pull(limit: 500)
        #expect(pull.changes.map(\.version) == Array(1...Int64(workers * perWorker)))
        #expect(pull.hasMore == false)
    }
}
