import Foundation
import SwiftData

/// A local edit waiting to be pushed: one per entity, the operation is a JSON snapshot taken at edit time.
@Model
final class PendingChangeEntity {
    @Attribute(.unique) var changeID: UUID
    /// `"<kind>:<uuid>"`, see `SyncQueue.refKey`.
    @Attribute(.unique) var refKey: String
    /// Edit order; a vehicle is queued before its records.
    var sequence: Int64
    var baseVersion: Int64?
    var modifiedAt: Date
    /// `ChangeOperation` encoded with `APICoding`.
    var operationJSON: Data

    init(
        changeID: UUID, refKey: String, sequence: Int64, baseVersion: Int64?, modifiedAt: Date,
        operationJSON: Data
    ) {
        self.changeID = changeID
        self.refKey = refKey
        self.sequence = sequence
        self.baseVersion = baseVersion
        self.modifiedAt = modifiedAt
        self.operationJSON = operationJSON
    }
}

/// The last known server version of an entity. Outlives the entity, so a deleted one keeps its tombstone version.
@Model
final class SyncVersionEntity {
    @Attribute(.unique) var refKey: String
    var kindRaw: String
    var entityID: UUID
    var version: Int64

    init(refKey: String, kindRaw: String, entityID: UUID, version: Int64) {
        self.refKey = refKey
        self.kindRaw = kindRaw
        self.entityID = entityID
        self.version = version
    }
}

/// Singleton with the sync bookkeeping (see `SyncState.current`).
@Model
final class SyncStateEntity {
    var cursor: String?
    var schemaVersion: Int
    var nextSequence: Int64
    var bootstrapped: Bool
    var lastSyncAt: Date?

    init(schemaVersion: Int) {
        self.schemaVersion = schemaVersion
        self.nextSequence = 0
        self.bootstrapped = false
    }
}
