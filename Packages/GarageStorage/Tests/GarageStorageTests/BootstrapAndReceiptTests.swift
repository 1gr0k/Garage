import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData
import Testing

@testable import GarageStorage

@Suite struct BootstrapAndReceiptTests {
    @Test func bootstrapQueuesVehiclesBeforeRecordsExactlyOnce() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        SampleSeeder.insertSamples(into: context)
        let entity = try #require(context.fetch(FetchDescriptor<VehicleEntity>()).first)
        let record = try makeSyncRecord(for: entity.toDomain())
        let recordEntity = try ServiceRecordEntity(record, vehicle: entity)
        context.insert(recordEntity)
        try context.save()

        try SyncSupport.prepare(container)
        try SyncSupport.prepare(container)

        let pending = try await pendingChanges(container)
        #expect(pending.count == 5)
        #expect(pending.prefix(4).allSatisfy { $0.operation.ref.kind == .vehicle })
        #expect(pending[4].operation.ref == EntityRef(kind: .serviceRecord, id: record.id))
        #expect(Set(pending.map(\.changeID)).count == 5)
        #expect(pending.allSatisfy { $0.baseVersion == nil })

        // Edits after bootstrap are not duplicated by a later prepare.
        try await SwiftDataSyncStore(modelContainer: container).discard(changeID: pending[0].changeID)
        try SyncSupport.prepare(container)
        #expect(try await pendingChanges(container).count == 4)
    }

    @Test func bootstrapSkipsEntitiesThatAlreadyHaveAVersion() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        SampleSeeder.insertSamples(into: context)
        try SyncState.setVersion(3, for: EntityRef(kind: .vehicle, id: Vehicle.SampleID.landCruiser), in: context)
        try context.save()

        try SyncSupport.prepare(container)

        #expect(try await pendingChanges(container).count == 3)
    }

    @Test func bootstrapBackfillsReceiptHashOfOldRecords() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        SampleSeeder.insertSamples(into: context)
        let vehicle = try #require(context.fetch(FetchDescriptor<VehicleEntity>()).first)
        let entity = try ServiceRecordEntity(makeSyncRecord(for: vehicle.toDomain()), vehicle: vehicle)
        entity.setReceiptImage(Data([5, 6]))
        entity.setReceiptImage(nil)
        entity.setReceiptImage(Data([5, 6]))
        context.insert(entity)
        try context.save()

        try SyncSupport.prepare(container)

        let stored = try #require(ModelContext(container).fetch(FetchDescriptor<ServiceRecordEntity>()).first)
        #expect(stored.receiptSHA256 == ServiceRecordEntity.sha256Hex(Data([5, 6])))
        #expect(stored.receiptByteCount == 2)
    }

    @Test func setReceiptImageComputesHashAndSize() {
        let entity = ServiceRecordEntity(
            id: UUID(), vehicle: nil, date: Date(), mileageKm: 0, serviceTypeRaw: "oilChange",
            laborCostKopecks: 0, notes: "")
        entity.setReceiptImage(Data("abc".utf8))

        // SHA-256("abc")
        #expect(entity.receiptSHA256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(entity.receiptByteCount == 3)
        #expect(entity.hasReceipt)

        entity.setReceiptImage(nil)
        #expect(entity.receiptSHA256 == nil && entity.receiptByteCount == nil && !entity.hasReceipt)
    }

    @Test func setReceiptRefKeepsMatchingBytesAndMarksOthersForDownload() {
        let entity = ServiceRecordEntity(
            id: UUID(), vehicle: nil, date: Date(), mileageKm: 0, serviceTypeRaw: "oilChange",
            laborCostKopecks: 0, notes: "")
        let data = Data("abc".utf8)
        entity.setReceiptImage(data)
        entity.setReceiptRef(ReceiptRefDTO(sha256: ServiceRecordEntity.sha256Hex(data), byteCount: 3))
        #expect(entity.receiptImage == data && !entity.receiptNeedsDownload)

        entity.setReceiptRef(ReceiptRefDTO(sha256: String(repeating: "d", count: 64), byteCount: 9))
        #expect(entity.receiptImage == nil && entity.receiptNeedsDownload && entity.hasReceipt)

        entity.setReceiptRef(nil)
        #expect(!entity.hasReceipt && !entity.receiptNeedsDownload && entity.receiptSHA256 == nil)
    }

    @Test func storeReceiptVerifiesHashAndSize() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: container)
        let data = Data("abc".utf8)
        let ref = ReceiptRefDTO(sha256: ServiceRecordEntity.sha256Hex(data), byteCount: 3)
        let store = SwiftDataSyncStore(modelContainer: container)
        let record = try makeSyncRecord(for: vehicle)
        try await store.apply(
            RemoteChange(
                version: 1, operation: .upsert(.serviceRecord(record, RecordSyncExtras(receipt: ref)))),
            for: EntityRef(kind: .serviceRecord, id: record.id))
        #expect(try await store.missingReceipts() == [ref])

        await #expect(throws: ReceiptBlobError.self) { try await store.storeReceipt(Data("xyz".utf8), for: ref) }
        await #expect(throws: ReceiptBlobError.self) {
            try await store.storeReceipt(
                data, for: ReceiptRefDTO(sha256: ref.sha256, byteCount: 4))
        }
        #expect(try await store.missingReceipts() == [ref])

        try await store.storeReceipt(data, for: ref)
        #expect(try await store.missingReceipts().isEmpty)
        #expect(try await store.receiptData(sha256: ref.sha256) == data)
    }
}
