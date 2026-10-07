import Foundation

/// Local persistence as the sync engine sees it. Methods are `async` so an adapter may live on the main actor.
///
/// Enqueueing local edits is deliberately not part of the protocol: the engine never needs it.
public protocol SyncStore: Sendable {
    /// The queue in edit order (a vehicle precedes its records). At most one entry per entity.
    func pendingChanges() async throws -> [PendingChange]
    func pendingChange(for ref: EntityRef) async throws -> PendingChange?
    /// The last known server version of the entity, including a tombstone's version.
    func version(of ref: EntityRef) async throws -> Int64?

    /// The change was accepted: drop it from the queue and remember the version.
    func markApplied(changeID: UUID, version: Int64) async throws
    /// The local edit won: keep it queued on top of `version`. Only `baseVersion` changes;
    /// `version(of:)` keeps the last version whose content was actually applied locally.
    func rebase(changeID: UUID, onto version: Int64) async throws
    /// Writes or deletes the entity, remembers the version (a deleted entity keeps its tombstone version,
    /// so an older upsert from pull cannot resurrect it) and drops the entity's pending edit.
    func apply(_ change: RemoteChange, for ref: EntityRef) async throws
    /// Drops the change from the queue without touching data.
    func discard(changeID: UUID) async throws

    func cursor() async throws -> String?
    func setCursor(_ cursor: String?) async throws
}
