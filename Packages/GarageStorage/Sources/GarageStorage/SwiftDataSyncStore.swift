import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData

public enum ReceiptBlobError: Error, Equatable, Sendable {
    case hashMismatch(expected: String)
    case sizeMismatch(expected: Int, actual: Int)
}

/// `SyncStore` and `ReceiptBlobStore` on SwiftData. All access goes through the actor's own `ModelContext`;
/// every call that changes data saves before it returns.
public actor SwiftDataSyncStore: ModelActor, SyncStore, ReceiptBlobStore {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    public init(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    // MARK: Queue

    public func pendingChanges() throws -> [PendingChange] {
        let descriptor = FetchDescriptor<PendingChangeEntity>(sortBy: [SortDescriptor(\.sequence)])
        let entities = try modelContext.fetch(descriptor)
        // An unreadable row (e.g. written by a future version) must not block the whole queue.
        return entities.compactMap { try? SyncQueue.pendingChange($0) }
    }

    public func pendingChange(for ref: EntityRef) throws -> PendingChange? {
        try SyncState.pendingEntity(for: ref, in: modelContext).flatMap { try? SyncQueue.pendingChange($0) }
    }

    public func pendingChangeCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<PendingChangeEntity>())
    }

    public func version(of ref: EntityRef) throws -> Int64? {
        try SyncState.versionEntity(for: ref, in: modelContext)?.version
    }

    public func markApplied(changeID: UUID, version: Int64) throws {
        guard let entity = try pendingEntity(changeID: changeID) else { return }
        let ref = try SyncQueue.pendingChange(entity).operation.ref
        try SyncState.setVersion(version, for: ref, in: modelContext)
        modelContext.delete(entity)
        try modelContext.save()
    }

    public func rebase(changeID: UUID, onto version: Int64) throws {
        guard let entity = try pendingEntity(changeID: changeID) else { return }
        entity.baseVersion = version
        try modelContext.save()
    }

    public func discard(changeID: UUID) throws {
        guard let entity = try pendingEntity(changeID: changeID) else { return }
        modelContext.delete(entity)
        try modelContext.save()
    }

    private func pendingEntity(changeID: UUID) throws -> PendingChangeEntity? {
        var descriptor = FetchDescriptor<PendingChangeEntity>(predicate: #Predicate { $0.changeID == changeID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    // MARK: Applying server data

    public func apply(_ change: RemoteChange, for ref: EntityRef) throws {
        do {
            switch change.operation {
            case .upsert(.vehicle(let vehicle)):
                if let entity = try vehicleEntity(vehicle.id) {
                    entity.update(from: vehicle)
                } else {
                    modelContext.insert(VehicleEntity(vehicle))
                }
            case .upsert(.serviceRecord(let record, let extras)):
                try upsert(record, extras: extras)
            case .delete(let target):
                try delete(target)
            }
            if let version = change.version { try SyncState.setVersion(version, for: ref, in: modelContext) }
            if let pending = try SyncState.pendingEntity(for: ref, in: modelContext) { modelContext.delete(pending) }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func upsert(_ record: ServiceRecord, extras: RecordSyncExtras) throws {
        guard let vehicle = try vehicleEntity(record.vehicleID) else {
            // Nothing has been changed yet; the engine reports the change as skipped.
            throw SyncStoreError(cannotApply: StorageMappingError.missingVehicle(record.vehicleID))
        }
        let entity: ServiceRecordEntity
        if let existing = try recordEntity(record.id) {
            entity = existing
            entity.vehicle = vehicle
            entity.update(from: record)
        } else {
            entity = try ServiceRecordEntity(record, vehicle: vehicle)
            modelContext.insert(entity)
        }
        entity.rawServiceType = extras.rawServiceType
        entity.setReceiptRef(extras.receipt)
    }

    private func delete(_ ref: EntityRef) throws {
        switch ref.kind {
        case .vehicle:
            if let entity = try vehicleEntity(ref.id) {
                // Контракт `SyncStore.apply`: записи уходят каскадом, их pending-upsert'ы — вместе с ними.
                try SyncQueue.dropPendingUpserts(ofRecordsOf: entity, in: modelContext)
                modelContext.delete(entity)
            }
        case .serviceRecord:
            if let entity = try recordEntity(ref.id) { modelContext.delete(entity) }
        }
    }

    private func vehicleEntity(_ id: UUID) throws -> VehicleEntity? {
        var descriptor = FetchDescriptor<VehicleEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func recordEntity(_ id: UUID) throws -> ServiceRecordEntity? {
        var descriptor = FetchDescriptor<ServiceRecordEntity>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    // MARK: Cursor and status

    public func cursor() throws -> String? {
        try SyncState.current(in: modelContext).cursor
    }

    public func setCursor(_ cursor: String?) throws {
        try SyncState.current(in: modelContext).cursor = cursor
        try modelContext.save()
    }

    public func lastSyncAt() throws -> Date? {
        try SyncState.current(in: modelContext).lastSyncAt
    }

    public func recordSyncFinished(at date: Date) throws {
        try SyncState.current(in: modelContext).lastSyncAt = date
        try modelContext.save()
    }

    // MARK: Receipt blobs

    public func receiptData(sha256: String) throws -> Data? {
        let descriptor = FetchDescriptor<ServiceRecordEntity>(predicate: #Predicate { $0.receiptSHA256 == sha256 })
        return try modelContext.fetch(descriptor).lazy.compactMap(\.receiptImage).first
    }

    public func missingReceipts() throws -> [ReceiptRefDTO] {
        let descriptor = FetchDescriptor<ServiceRecordEntity>(predicate: #Predicate { $0.receiptNeedsDownload })
        return try modelContext.fetch(descriptor).compactMap { entity in
            guard let sha = entity.receiptSHA256 else { return nil }
            return ReceiptRefDTO(sha256: sha, byteCount: entity.receiptByteCount ?? 0)
        }
    }

    public func storeReceipt(_ data: Data, for ref: ReceiptRefDTO) throws {
        guard ServiceRecordEntity.sha256Hex(data) == ref.sha256 else {
            throw ReceiptBlobError.hashMismatch(expected: ref.sha256)
        }
        guard data.count == ref.byteCount else {
            throw ReceiptBlobError.sizeMismatch(expected: ref.byteCount, actual: data.count)
        }
        let sha = ref.sha256
        let descriptor = FetchDescriptor<ServiceRecordEntity>(
            predicate: #Predicate { $0.receiptSHA256 == sha && $0.receiptNeedsDownload })
        for entity in try modelContext.fetch(descriptor) { entity.storeDownloadedReceipt(data) }
        try modelContext.save()
    }
}
