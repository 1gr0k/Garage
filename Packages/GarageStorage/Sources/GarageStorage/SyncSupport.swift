import Foundation
import GarageSync
import SwiftData

/// Sync housekeeping the app runs when it opens the store.
public enum SyncSupport {
    /// Checks the stored schema version and runs the one-time bootstrap. Idempotent and cheap once done.
    public static func prepare(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try resetIfSchemaChanged(in: context)
        try bootstrapIfNeeded(in: context)
        try context.save()
    }

    /// After a model change the remembered versions may be stale (new fields were never filled from the server),
    /// so forget the cursor and the versions: the next sync downloads everything again.
    /// Queued edits keep their `baseVersion`.
    static func resetIfSchemaChanged(in context: ModelContext) throws {
        let state = try SyncState.current(in: context)
        guard state.schemaVersion != GarageStore.schemaVersion else { return }
        state.cursor = nil
        let pendingKeys = Set(try context.fetch(FetchDescriptor<PendingChangeEntity>()).map(\.refKey))
        for version in try context.fetch(FetchDescriptor<SyncVersionEntity>())
        where !pendingKeys.contains(version.refKey) {
            context.delete(version)
        }
        state.schemaVersion = GarageStore.schemaVersion
    }

    /// Queues everything that exists locally but never went through sync (once per store):
    /// vehicles first, then records and rules, so a vehicle always precedes its children.
    static func bootstrapIfNeeded(in context: ModelContext) throws {
        let state = try SyncState.current(in: context)
        guard !state.bootstrapped else { return }

        let records = try context.fetch(FetchDescriptor<ServiceRecordEntity>())
        for record in records where record.receiptSHA256 == nil {
            if let image = record.receiptImage { record.setReceiptImage(image) }
        }

        let known = Set(try context.fetch(FetchDescriptor<PendingChangeEntity>()).map(\.refKey))
            .union(try context.fetch(FetchDescriptor<SyncVersionEntity>()).map(\.refKey))
        let vehicles = try context.fetch(
            FetchDescriptor<VehicleEntity>(sortBy: [SortDescriptor(\.make), SortDescriptor(\.model)]))
        // An entity that cannot be mapped is left out; bootstrap then stays open and is retried on the next start.
        var skipped = false
        for entity in vehicles {
            let ref = EntityRef(kind: .vehicle, id: entity.id)
            guard !known.contains(SyncState.refKey(ref)) else { continue }
            guard let vehicle = try? entity.toDomain() else {
                skipped = true
                continue
            }
            try SyncQueue.enqueueUpsert(.vehicle(vehicle, entity.syncExtras), in: context)
        }
        for entity in records.sorted(by: { $0.date < $1.date }) {
            let ref = EntityRef(kind: .serviceRecord, id: entity.id)
            guard !known.contains(SyncState.refKey(ref)) else { continue }
            guard let record = try? entity.toDomain() else {
                skipped = true
                continue
            }
            try SyncQueue.enqueueUpsert(.serviceRecord(record, entity.syncExtras), in: context)
        }
        // Правила — после машин. Без них «Забыть устройство» (`resetSyncState`) не отправило бы правила на новый сервер.
        for entity in try context.fetch(FetchDescriptor<MaintenanceRuleEntity>()).sorted(by: {
            $0.startDate < $1.startDate
        }) {
            let ref = EntityRef(kind: .maintenanceRule, id: entity.id)
            guard !known.contains(SyncState.refKey(ref)) else { continue }
            guard let rule = try? entity.toDomain() else {
                skipped = true
                continue
            }
            try SyncQueue.enqueueUpsert(.maintenanceRule(rule, entity.syncExtras), in: context)
        }
        state.bootstrapped = !skipped
    }

    /// Forgets everything remembered about a server (cursor, versions, queued base versions) and re-opens
    /// bootstrap, for use when the device is unregistered: another server must not see this one's state.
    public static func resetSyncState(_ container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let state = try SyncState.current(in: context)
        state.cursor = nil
        state.lastSyncAt = nil
        state.bootstrapped = false
        for version in try context.fetch(FetchDescriptor<SyncVersionEntity>()) { context.delete(version) }
        for pending in try context.fetch(FetchDescriptor<PendingChangeEntity>()) { pending.baseVersion = nil }
        try bootstrapIfNeeded(in: context)
        try context.save()
    }
}
