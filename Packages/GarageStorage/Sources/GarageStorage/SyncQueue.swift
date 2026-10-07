import Foundation
import GarageAPI
import GarageSync
import SwiftData

enum SyncState {
    /// The singleton state row; created on first use.
    static func current(in context: ModelContext) throws -> SyncStateEntity {
        var descriptor = FetchDescriptor<SyncStateEntity>()
        descriptor.fetchLimit = 1
        if let state = try context.fetch(descriptor).first { return state }
        let state = SyncStateEntity(schemaVersion: GarageStore.schemaVersion)
        context.insert(state)
        return state
    }

    static func refKey(_ ref: EntityRef) -> String {
        "\(ref.kind.rawValue):\(ref.id.uuidString)"
    }

    static func versionEntity(for ref: EntityRef, in context: ModelContext) throws -> SyncVersionEntity? {
        let key = refKey(ref)
        var descriptor = FetchDescriptor<SyncVersionEntity>(predicate: #Predicate { $0.refKey == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func setVersion(_ version: Int64, for ref: EntityRef, in context: ModelContext) throws {
        if let existing = try versionEntity(for: ref, in: context) {
            existing.version = version
        } else {
            context.insert(
                SyncVersionEntity(
                    refKey: refKey(ref), kindRaw: ref.kind.rawValue, entityID: ref.id, version: version))
        }
    }

    static func pendingEntity(for ref: EntityRef, in context: ModelContext) throws -> PendingChangeEntity? {
        let key = refKey(ref)
        var descriptor = FetchDescriptor<PendingChangeEntity>(predicate: #Predicate { $0.refKey == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

/// Puts local edits into the sync queue. It works in the caller's context and does not save, so the edit
/// and its queue entry are written in one transaction.
enum SyncQueue {
    static func enqueueUpsert(_ entity: SyncEntity, in context: ModelContext) throws {
        try enqueue(.upsert(entity), in: context)
    }

    static func enqueueDelete(_ ref: EntityRef, in context: ModelContext) throws {
        try enqueue(.delete(ref), in: context)
    }

    private static func enqueue(_ operation: LocalOperation, in context: ModelContext) throws {
        let ref = operation.ref
        // `PendingChange` rounds `modifiedAt` to the wire precision (milliseconds).
        let change = PendingChange(changeID: UUID(), baseVersion: nil, modifiedAt: Date(), operation: operation)
        let json = try APICoding.makeEncoder().encode(operation.changeOperation)

        if let existing = try SyncState.pendingEntity(for: ref, in: context) {
            // A newer edit of the same entity replaces the queued one but keeps its base version and place.
            existing.changeID = change.changeID
            existing.modifiedAt = change.modifiedAt
            existing.operationJSON = json
            return
        }
        let state = try SyncState.current(in: context)
        let base = try SyncState.versionEntity(for: ref, in: context)?.version
        context.insert(
            PendingChangeEntity(
                changeID: change.changeID, refKey: SyncState.refKey(ref), sequence: state.nextSequence,
                baseVersion: base, modifiedAt: change.modifiedAt, operationJSON: json))
        state.nextSequence += 1
    }

    static func pendingChange(_ entity: PendingChangeEntity) throws -> PendingChange {
        let decoded = try APICoding.makeDecoder().decode(ChangeOperation.self, from: entity.operationJSON)
        let operation = try LocalOperation(decoded)
        return PendingChange(
            changeID: entity.changeID, baseVersion: entity.baseVersion, modifiedAt: entity.modifiedAt,
            operation: operation)
    }
}
