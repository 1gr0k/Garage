import Foundation
import GarageAPI

public struct SyncReport: Sendable {
    /// Local changes the server accepted (including conflicts that turned out to be our own change).
    public var pushed = 0
    public var conflictsResolved = 0
    public var rejected: [(ref: EntityRef, error: APIError)] = []
    /// Server changes applied to local data.
    public var pulled = 0
    /// Server changes that could not be mapped to the domain and were left out.
    public var skipped: [(ref: EntityRef, error: any Error)] = []

    public init() {}
}

/// Push the queue → pull until `hasMore == false` → keep the cursor. Conflicts are resolved
/// last-write-wins by `modifiedAt` (ties go to the server); deletion always wins.
public actor SyncEngine {
    /// Rounds of push while rebased edits remain; bounds a ping-pong with another device.
    private static let maxPushRounds = 3

    private let store: any SyncStore
    private let client: SyncAPIClient
    private let pullLimit: Int

    public init(store: any SyncStore, client: SyncAPIClient, pullLimit: Int = APIPath.defaultPullLimit) {
        self.store = store
        self.client = client
        self.pullLimit = min(max(pullLimit, 1), APIPath.maxPullLimit)
    }

    /// Concurrent callers share one run: the actor is reentrant, so overlapping runs would push the same batch twice.
    public func sync() async throws -> SyncReport {
        if let running = inFlight { return try await running.value }
        let task = Task { try await self.run() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private var inFlight: Task<SyncReport, any Error>?
    /// Vehicles the server refused to validate in the current run; their records are not deleted locally.
    private var rejectedVehicles: Set<UUID> = []

    private func run() async throws -> SyncReport {
        var report = SyncReport()
        rejectedVehicles = []
        try await push(&report)
        try await pull(&report)
        return report
    }

    // MARK: Push

    private func push(_ report: inout SyncReport) async throws {
        for _ in 0..<Self.maxPushRounds {
            let pending = try await store.pendingChanges()
            guard !pending.isEmpty else { return }
            var rebased = false
            for start in stride(from: 0, to: pending.count, by: APIPath.maxPushBatch) {
                let batch = Array(pending[start..<min(start + APIPath.maxPushBatch, pending.count)])
                let response = try await client.push(PushRequest(changes: batch.map(\.pushChange)))
                guard response.results.count == batch.count,
                    zip(batch, response.results).allSatisfy({ $0.changeID == $1.changeID })
                else { throw SyncError.malformedResponse }
                for (change, result) in zip(batch, response.results) {
                    if try await resolve(change, outcome: result.outcome, report: &report) { rebased = true }
                }
            }
            if !rebased { return }
        }
    }

    /// Returns `true` when the change stays queued on a new base version.
    private func resolve(_ change: PendingChange, outcome: PushOutcome, report: inout SyncReport) async throws -> Bool {
        let ref = change.operation.ref
        switch outcome {
        case .applied(let version):
            try await store.markApplied(changeID: change.changeID, version: version)
            report.pushed += 1
            return false

        case .conflict(let reason, let current):
            if current.operation == change.pushChange.operation {
                // Our own change came back (e.g. the response to an earlier push was lost).
                try await store.markApplied(changeID: change.changeID, version: current.version)
                report.pushed += 1
                return false
            }
            report.conflictsResolved += 1
            let serverWins: Bool
            if current.operation.isDelete {
                serverWins = true
            } else if change.operation.isDelete {
                serverWins = false
            } else if reason == .deleted {
                serverWins = true
            } else {
                serverWins = !(change.modifiedAt > current.modifiedAt)
            }
            if serverWins {
                try await applyServerChange(current, for: ref, report: &report)
                return false
            }
            try await store.rebase(changeID: change.changeID, onto: current.version)
            return true

        case .rejected(let error):
            report.rejected.append((ref, error))
            if ref.kind == .vehicle { rejectedVehicles.insert(ref.id) }
            var vehicleWasRejected = false
            if case .upsert(.serviceRecord(let record, _)) = change.operation {
                vehicleWasRejected = rejectedVehicles.contains(record.vehicleID)
            }
            if error.code == .vehicleNotFound, ref.kind == .serviceRecord, !change.operation.isDelete,
                !vehicleWasRejected
            {
                try await store.apply(RemoteChange(version: nil, operation: .delete(ref)), for: ref)
            } else {
                // Keep local data; retrying the same invalid change would loop.
                try await store.discard(changeID: change.changeID)
            }
            return false
        }
    }

    /// Applies a server change; if it cannot be mapped the local edit stays queued and the failure is reported.
    private func applyServerChange(_ change: ServerChange, for ref: EntityRef, report: inout SyncReport) async throws {
        let operation: LocalOperation
        do {
            operation = try LocalOperation(change.operation)
        } catch {
            report.skipped.append((ref, error))
            return
        }
        try await store.apply(RemoteChange(version: change.version, operation: operation), for: ref)
    }

    // MARK: Pull

    private func pull(_ report: inout SyncReport) async throws {
        var cursor = try await store.cursor()
        while true {
            let page: PullResponse
            do {
                page = try await client.pull(after: cursor, limit: pullLimit)
            } catch SyncError.api(_, let error) where error.code == .cursorExpired && cursor != nil {
                try await store.setCursor(nil)
                cursor = nil
                continue
            }
            for change in page.changes {
                try await applyPulled(change, report: &report)
            }
            try await store.setCursor(page.cursor)
            if !page.hasMore { return }
            guard page.cursor != cursor else { throw SyncError.malformedResponse }
            cursor = page.cursor
        }
    }

    private func applyPulled(_ change: ServerChange, report: inout SyncReport) async throws {
        let ref = change.operation.ref
        if let known = try await store.version(of: ref), known >= change.version { return }

        if let local = try await store.pendingChange(for: ref), !change.operation.isDelete {
            report.conflictsResolved += 1
            if local.operation.isDelete || local.modifiedAt > change.modifiedAt {
                try await store.rebase(changeID: local.changeID, onto: change.version)
                return
            }
        }
        let before = report.skipped.count
        try await applyServerChange(change, for: ref, report: &report)
        if report.skipped.count == before { report.pulled += 1 }
    }
}
