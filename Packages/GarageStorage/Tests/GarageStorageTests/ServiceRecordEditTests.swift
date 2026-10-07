import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData
import Testing

@testable import GarageStorage

/// Хранилище с машиной и записью; `synced == true` имитирует уже отправленные на сервер сущности.
private func makeStore(
    synced: Bool, receipt: Data? = nil, parts: [Part] = []
) throws -> (container: ModelContainer, vehicle: Vehicle, record: ServiceRecord) {
    let container = try GarageStore.makeContainer(inMemory: true)
    let vehicle = Vehicle.samples[0]
    try VehicleLog.add(vehicle, in: container)
    let record = try ServiceRecord(
        vehicleID: vehicle.id, date: Date(timeIntervalSince1970: 1_700_000_000), mileageKm: 1000,
        serviceType: .oilChange, laborCost: Money(rubles: 100), notes: "до", parts: parts)
    try ServiceLog.add(record, receiptImage: receipt, toVehicleWithID: vehicle.id, in: container)
    if synced {
        let context = ModelContext(container)
        for pending in try context.fetch(FetchDescriptor<PendingChangeEntity>()) { context.delete(pending) }
        try SyncState.setVersion(5, for: EntityRef(kind: .vehicle, id: vehicle.id), in: context)
        try SyncState.setVersion(5, for: EntityRef(kind: .serviceRecord, id: record.id), in: context)
        try context.save()
    }
    return (container, vehicle, record)
}

private func storedRecord(_ id: UUID, in container: ModelContainer) throws -> ServiceRecordEntity? {
    try ModelContext(container).fetch(FetchDescriptor<ServiceRecordEntity>()).first { $0.id == id }
}

private func edited(_ record: ServiceRecord, notes: String, parts: [Part]? = nil, type: ServiceType? = nil) throws
    -> ServiceRecord
{
    try ServiceRecord(
        id: record.id, vehicleID: record.vehicleID, date: record.date, mileageKm: record.mileageKm + 10,
        serviceType: type ?? record.serviceType, laborCost: record.laborCost, notes: notes,
        parts: parts ?? record.parts)
}

@Suite struct ServiceRecordEditTests {
    @Test func updateReplacesFieldsAndKeepsPartIDs() async throws {
        let part = try Part(name: "Фильтр", partNumber: "F-1", unitPrice: Money(rubles: 50), quantity: 1)
        let (container, _, record) = try makeStore(synced: true, parts: [part])
        let changed = try edited(
            record, notes: "после",
            parts: [try Part(id: part.id, name: "Фильтр масляный", unitPrice: Money(rubles: 60), quantity: 2)])

        try ServiceLog.update(changed, receipt: .keep, in: container)

        let entity = try #require(try storedRecord(record.id, in: container))
        #expect(try entity.toDomain() == changed)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PartEntity>()) == 1)
        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].baseVersion == 5)
        #expect(pending[0].operation == .upsert(.serviceRecord(changed, RecordSyncExtras())))
    }

    @Test func twoUpdatesCollapseKeepingBaseVersion() async throws {
        let (container, _, record) = try makeStore(synced: true)
        try ServiceLog.update(try edited(record, notes: "1"), receipt: .keep, in: container)
        let first = try await pendingChanges(container)
        let last = try edited(record, notes: "2")
        try ServiceLog.update(last, receipt: .keep, in: container)

        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].baseVersion == 5)
        #expect(pending[0].changeID != first[0].changeID)
        #expect(pending[0].operation == .upsert(.serviceRecord(last, RecordSyncExtras())))
    }

    @Test func receiptChangesKeepDerivedFieldsConsistent() async throws {
        let old = Data([1, 2, 3])
        let new = Data([9, 8, 7, 6])
        let (container, _, record) = try makeStore(synced: true, receipt: old)

        try ServiceLog.update(record, receipt: .replace(new), in: container)
        var entity = try #require(try storedRecord(record.id, in: container))
        #expect(entity.receiptImage == new)
        #expect(entity.hasReceipt && entity.receiptSHA256 == ServiceRecordEntity.sha256Hex(new))
        #expect(entity.receiptByteCount == 4)
        var pending = try await pendingChanges(container)
        let ref = ReceiptRefDTO(sha256: ServiceRecordEntity.sha256Hex(new), byteCount: 4)
        #expect(pending[0].operation == .upsert(.serviceRecord(record, RecordSyncExtras(receipt: ref))))

        try ServiceLog.update(record, receipt: .keep, in: container)
        entity = try #require(try storedRecord(record.id, in: container))
        #expect(entity.receiptImage == new && entity.receiptSHA256 == ServiceRecordEntity.sha256Hex(new))

        try ServiceLog.update(record, receipt: .remove, in: container)
        entity = try #require(try storedRecord(record.id, in: container))
        #expect(entity.receiptImage == nil && entity.receiptSHA256 == nil && !entity.hasReceipt)
        #expect(entity.receiptByteCount == nil)
        pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].operation == .upsert(.serviceRecord(record, RecordSyncExtras(receipt: nil))))
    }

    @Test func keepLeavesNotYetDownloadedReceiptAlone() async throws {
        let (container, _, record) = try makeStore(synced: true)
        let ref = ReceiptRefDTO(sha256: String(repeating: "a", count: 64), byteCount: 42)
        let context = ModelContext(container)
        let entity = try #require(try context.fetch(FetchDescriptor<ServiceRecordEntity>()).first)
        entity.setReceiptRef(ref)
        try context.save()

        try ServiceLog.update(try edited(record, notes: "x"), receipt: .keep, in: container)

        let stored = try #require(try storedRecord(record.id, in: container))
        #expect(stored.receiptNeedsDownload && stored.hasReceipt)
        #expect(stored.receiptImage == nil && stored.receiptSHA256 == ref.sha256 && stored.receiptByteCount == 42)
        let pending = try await pendingChanges(container)
        #expect(
            pending[0].operation
                == .upsert(.serviceRecord(try edited(record, notes: "x"), RecordSyncExtras(receipt: ref))))
    }

    @Test func rawServiceTypeSurvivesUntouchedTypeAndIsDroppedOnChange() async throws {
        let (container, _, record) = try makeStore(synced: true)
        let context = ModelContext(container)
        let entity = try #require(try context.fetch(FetchDescriptor<ServiceRecordEntity>()).first)
        entity.serviceTypeRaw = ServiceType.other("wash").storageString
        entity.rawServiceType = "wash"
        try context.save()

        let untouched = try edited(record, notes: "x", type: .other("wash"))
        try ServiceLog.update(untouched, receipt: .keep, in: container)
        #expect(try #require(try storedRecord(record.id, in: container)).rawServiceType == "wash")

        try ServiceLog.update(try edited(record, notes: "y", type: .brakes), receipt: .keep, in: container)
        #expect(try #require(try storedRecord(record.id, in: container)).rawServiceType == nil)
        let pending = try await pendingChanges(container)
        guard case .upsert(.serviceRecord(_, let extras)) = pending[0].operation else {
            Issue.record("expected an upsert")
            return
        }
        #expect(extras.rawServiceType == nil)
    }

    @Test func updateOfMissingRecordThrowsAndQueuesNothing() async throws {
        let (container, _, record) = try makeStore(synced: true)
        let missing = try edited(record, notes: "x")
        let other = try ServiceRecord(
            id: UUID(), vehicleID: missing.vehicleID, date: missing.date, mileageKm: 1, serviceType: .repair,
            laborCost: .zero)

        await #expect(throws: RepositoryError.recordNotFound(other.id)) {
            try await SwiftDataServiceRecordRepository(container: container).update(other, receipt: .keep)
        }
        #expect(try await pendingChanges(container).isEmpty)
    }

    @Test func failedUpdateSaveChangesNothing() async throws {
        let (container, _, record) = try makeStore(synced: true)
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try ServiceLog.update(try edited(record, notes: "x"), receipt: .remove, in: container) { _ in throw Boom() }
        }
        #expect(try #require(try storedRecord(record.id, in: container)).notes == "до")
        #expect(try await pendingChanges(container).isEmpty)
    }

    @Test func deleteOfSyncedRecordQueuesDeleteWithBaseVersion() async throws {
        let part = try Part(name: "Фильтр", unitPrice: Money(rubles: 50), quantity: 1)
        let (container, _, record) = try makeStore(synced: true, receipt: Data([1]), parts: [part])

        try await SwiftDataServiceRecordRepository(container: container).delete(id: record.id)

        #expect(try storedRecord(record.id, in: container) == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PartEntity>()) == 0)
        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].baseVersion == 5)
        #expect(pending[0].operation == .delete(EntityRef(kind: .serviceRecord, id: record.id)))
    }

    @Test func deleteAfterPendingEditCollapsesIntoOneDelete() async throws {
        let (container, _, record) = try makeStore(synced: true)
        try ServiceLog.update(try edited(record, notes: "x"), receipt: .keep, in: container)

        try ServiceLog.delete(id: record.id, in: container)

        let pending = try await pendingChanges(container)
        #expect(pending.count == 1)
        #expect(pending[0].baseVersion == 5)
        #expect(pending[0].operation.isDelete)
    }

    @Test func deleteOfNeverSyncedRecordCollapsesPendingUpsertIntoDelete() async throws {
        let (container, vehicle, record) = try makeStore(synced: false, receipt: Data([1]))
        #expect(try await pendingChanges(container).count == 2)

        try ServiceLog.delete(id: record.id, in: container)

        #expect(try storedRecord(record.id, in: container) == nil)
        let pending = try await pendingChanges(container)
        #expect(
            pending.map(\.operation.ref) == [
                EntityRef(kind: .vehicle, id: vehicle.id), EntityRef(kind: .serviceRecord, id: record.id),
            ])
        #expect(pending[1].baseVersion == nil)
        #expect(pending[1].operation.isDelete)
    }

    @Test func deleteOfMissingRecordIsQuietNoOp() async throws {
        let (container, _, _) = try makeStore(synced: true)

        try await SwiftDataServiceRecordRepository(container: container).delete(id: UUID())

        #expect(try await pendingChanges(container).isEmpty)
    }

    @Test func editingSnapshotCarriesRecordAndReceipt() throws {
        let photo = Data([4, 5])
        let (container, _, record) = try makeStore(synced: true, receipt: photo)
        let entity = try #require(try storedRecord(record.id, in: container))

        let snapshot = try entity.editingSnapshot()

        #expect(snapshot.record == record && snapshot.hasReceipt && snapshot.receiptImage == photo)
    }
}
