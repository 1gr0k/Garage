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
    /// Edits still queued after the push rounds ran out (they go out on the next sync).
    public var stillPending: [PendingChange] = []
    /// Receipt uploads or downloads that failed; the affected edits/records are retried on the next sync.
    public var receiptFailures: [(sha256: String, error: any Error)] = []

    public init() {}
}

/// The local blob store failed (as opposed to the server or the network).
private struct ReceiptStoreFailure: Error {
    var underlying: any Error
}

/// Push the queue → pull until `hasMore == false` → keep the cursor. Conflicts are resolved
/// last-write-wins by `modifiedAt` (ties go to the server); deletion always wins.
public actor SyncEngine {
    /// Rounds of push while rebased edits remain; bounds a ping-pong with another device.
    private static let maxPushRounds = 3

    private let store: any SyncStore
    private let client: SyncAPIClient
    private let receipts: (any ReceiptBlobStore)?
    private let pullLimit: Int

    /// Without `receipts` the engine syncs records only and leaves receipt photos alone.
    public init(
        store: any SyncStore, client: SyncAPIClient, receipts: (any ReceiptBlobStore)? = nil,
        pullLimit: Int = APIPath.defaultPullLimit
    ) {
        self.store = store
        self.client = client
        self.receipts = receipts
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
    /// Receipt hashes the server has (or just got) in the current run.
    private var uploadedReceipts: Set<String> = []
    private var failedReceipts: Set<String> = []

    private func run() async throws -> SyncReport {
        var report = SyncReport()
        rejectedVehicles = []
        uploadedReceipts = []
        failedReceipts = []
        try await push(&report)
        try await pull(&report)
        try await downloadMissingReceipts(&report)
        return report
    }

    // MARK: Push

    private func push(_ report: inout SyncReport) async throws {
        var held = false
        var settled = false
        for _ in 0..<Self.maxPushRounds {
            let queued = try await store.pendingChanges()
            guard !queued.isEmpty else { return }
            let pending = try await uploadReceipts(for: queued, report: &report)
            if pending.count < queued.count { held = true }
            guard !pending.isEmpty else {
                settled = true
                break
            }
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
            if !rebased {
                settled = true
                break
            }
        }
        if held || !settled { report.stillPending = try await store.pendingChanges() }
    }

    /// Uploads the receipt blobs the batch refers to (the server rejects a record whose blob is missing).
    /// Returns the changes that may be pushed: an edit whose blob could not be uploaded stays queued.
    private func uploadReceipts(for changes: [PendingChange], report: inout SyncReport) async throws -> [PendingChange]
    {
        guard let receipts else { return changes }
        var sendable: [PendingChange] = []
        for change in changes {
            guard case .upsert(.serviceRecord(_, let extras)) = change.operation, let ref = extras.receipt else {
                sendable.append(change)
                continue
            }
            let sha256 = ref.sha256
            if uploadedReceipts.contains(sha256) {
                sendable.append(change)
                continue
            }
            if failedReceipts.contains(sha256) { continue }
            do {
                let data: Data?
                do {
                    data = try await receipts.receiptData(sha256: sha256)
                } catch {
                    throw ReceiptStoreFailure(underlying: error)
                }
                if let data { try await client.uploadReceipt(sha256: sha256, data: data) }
                uploadedReceipts.insert(sha256)
                sendable.append(change)
            } catch let failure as ReceiptStoreFailure {
                failedReceipts.insert(sha256)
                report.receiptFailures.append((sha256, failure.underlying))
            } catch let error as SyncError {
                // The server answered with a refusal: this edit waits, the rest goes on. Transport errors propagate.
                failedReceipts.insert(sha256)
                report.receiptFailures.append((sha256, error))
            }
        }
        return sendable
    }

    // MARK: Receipt download

    private func downloadMissingReceipts(_ report: inout SyncReport) async throws {
        guard let receipts else { return }
        let missing: [ReceiptRefDTO]
        do {
            missing = try await receipts.missingReceipts()
        } catch {
            report.receiptFailures.append(("", error))
            return
        }
        var seen: Set<String> = []
        for ref in missing where seen.insert(ref.sha256).inserted {
            do {
                let data = try await client.downloadReceipt(sha256: ref.sha256)
                try await receipts.storeReceipt(data, for: ref)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Not fatal: the record stays marked as missing its photo and is retried on the next sync.
                report.receiptFailures.append((ref.sha256, error))
            }
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
                if try await !applyServerChange(current, for: ref, report: &report) {
                    // The server state cannot be represented locally; retrying would conflict forever.
                    try await store.discard(changeID: change.changeID)
                }
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
    @discardableResult
    private func applyServerChange(
        _ change: ServerChange, for ref: EntityRef, report: inout SyncReport
    ) async throws -> Bool {
        let operation: LocalOperation
        do {
            operation = try LocalOperation(change.operation)
        } catch {
            report.skipped.append((ref, error))
            return false
        }
        do {
            try await store.apply(RemoteChange(version: change.version, operation: operation), for: ref)
        } catch let error as SyncStoreError {
            report.skipped.append((ref, error.reason))
            return false
        }
        return true
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
            if local.pushChange.operation == change.operation {
                // Our own edit came back (its push response was lost): nothing to resolve.
                try await store.markApplied(changeID: local.changeID, version: change.version)
                report.pushed += 1
                return
            }
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
