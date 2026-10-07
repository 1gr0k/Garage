import Foundation
import GarageAPI
import GarageSync

/// A stateful stand-in for the server with just enough of `/v1/changes` and `/v1/receipts`
/// (versions, `baseVersion` checks, pull by version) to run the real `SyncEngine` against it.
actor FakeSyncServer: HTTPTransport {
    private struct Key: Hashable {
        var kind: EntityKind
        var id: UUID
    }

    private var current: [Key: ServerChange] = [:]
    private var lastVersion: Int64 = 0
    private(set) var blobs: [String: Data] = [:]
    private(set) var requests: [HTTPRequest] = []

    /// Live (not deleted) entities of a kind.
    func liveCount(_ kind: EntityKind) -> Int {
        current.filter { $0.key.kind == kind && !$0.value.operation.isDelete }.count
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        switch (request.method, request.path) {
        case ("GET", APIPath.changes): return try pull(request)
        case ("POST", APIPath.changes): return try push(request)
        case ("PUT", let path) where path.hasPrefix(APIPath.receipts + "/"):
            let sha = String(path.dropFirst(APIPath.receipts.count + 1))
            let isNew = blobs[sha] == nil
            blobs[sha] = request.body
            return HTTPResponse(status: isNew ? 201 : 200, body: Data())
        case ("GET", let path) where path.hasPrefix(APIPath.receipts + "/"):
            let sha = String(path.dropFirst(APIPath.receipts.count + 1))
            guard let blob = blobs[sha] else { return try error(.notFound, status: 404) }
            return HTTPResponse(status: 200, body: blob)
        default:
            return try error(.notFound, status: 404)
        }
    }

    private func error(_ code: APIErrorCode, status: Int) throws -> HTTPResponse {
        HTTPResponse(
            status: status,
            body: try APICoding.makeEncoder().encode(APIErrorResponse(error: APIError(code: code, message: "fake"))))
    }

    private func pull(_ request: HTTPRequest) throws -> HTTPResponse {
        let after = request.query.first { $0.name == APIPath.afterQuery }?.value.flatMap(Int64.init) ?? 0
        let limit = request.query.first { $0.name == APIPath.limitQuery }?.value.flatMap(Int.init) ?? 200
        let newer = current.values.filter { $0.version > after }.sorted { $0.version < $1.version }
        let page = Array(newer.prefix(limit))
        let cursor = String(page.last?.version ?? after)
        let response = PullResponse(changes: page, cursor: cursor, hasMore: newer.count > page.count)
        return HTTPResponse(status: 200, body: try APICoding.makeEncoder().encode(response))
    }

    private func push(_ request: HTTPRequest) throws -> HTTPResponse {
        let decoded = try APICoding.makeDecoder().decode(PushRequest.self, from: request.body ?? Data())
        let results = decoded.changes.map { PushResult(changeID: $0.changeID, outcome: outcome(for: $0)) }
        return HTTPResponse(status: 200, body: try APICoding.makeEncoder().encode(PushResponse(results: results)))
    }

    private func outcome(for change: PushChange) -> PushOutcome {
        let key: Key
        switch change.operation {
        case .upsert(let payload): key = Key(kind: payload.kind, id: payload.id)
        case .delete(let kind, let id): key = Key(kind: kind, id: id)
        }
        if let existing = current[key] {
            if existing.operation.isDelete { return .conflict(reason: .deleted, current: existing) }
            if change.baseVersion == nil { return .conflict(reason: .alreadyExists, current: existing) }
            if change.baseVersion != existing.version { return .conflict(reason: .versionMismatch, current: existing) }
        } else if change.baseVersion != nil, case .upsert = change.operation {
            return .rejected(APIError(code: .validationFailed, message: "unknown base version"))
        }
        if case .upsert(.serviceRecord(let record)) = change.operation {
            guard current[Key(kind: .vehicle, id: record.vehicleID)].map({ !$0.operation.isDelete }) == true else {
                return .rejected(APIError(code: .vehicleNotFound, message: "no vehicle"))
            }
            if let receipt = record.receipt, blobs[receipt.sha256] == nil {
                return .rejected(APIError(code: .receiptNotFound, message: "no blob"))
            }
        }
        lastVersion += 1
        current[key] = ServerChange(version: lastVersion, modifiedAt: change.modifiedAt, operation: change.operation)
        return .applied(version: lastVersion)
    }
}

extension ChangeOperation {
    fileprivate var isDelete: Bool {
        if case .delete = self { true } else { false }
    }
}
