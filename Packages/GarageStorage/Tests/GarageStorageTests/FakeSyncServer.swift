import Foundation
import GarageAPI
import GarageSync

/// A stateful stand-in for the server with just enough of `/v1/changes` and `/v1/receipts`
/// (versions, `baseVersion` checks, pull by version) to run the real `SyncEngine` against it.
///
/// Удаление повторяет `ChangeWriter.delete` (Server/Sources/App/ChangeWriter.swift): delete никогда не
/// отклоняется и не конфликтует, несуществующий id получает tombstone, повторное удаление возвращает
/// версию существующего tombstone, а удаление машины каскадно ставит tombstones её живых записей.
actor FakeSyncServer: HTTPTransport {
    private struct Key: Hashable {
        var kind: EntityKind
        var id: UUID
    }

    /// Строка сервера (`EntityRow`): запись хранит `vehicleID`, по нему идёт каскад.
    private struct Row {
        var change: ServerChange
        var vehicleID: UUID?
        var lastChangeID: UUID
    }

    private var rows: [Key: Row] = [:]
    private var lastVersion: Int64 = 0
    private(set) var blobs: [String: Data] = [:]
    private(set) var requests: [HTTPRequest] = []

    private var downloadsBlocked = false
    private var blockedDownloads: [CheckedContinuation<Void, Never>] = []
    private var blockedDownloadWaiters: [CheckedContinuation<Void, Never>] = []

    /// Live (not deleted) entities of a kind.
    func liveCount(_ kind: EntityKind) -> Int {
        rows.filter { $0.key.kind == kind && !$0.value.change.operation.isDelete }.count
    }

    /// Версия строки сервера (живой или tombstone); `nil`, если сервер сущности не видел.
    func version(of kind: EntityKind, id: UUID) -> Int64? {
        rows[Key(kind: kind, id: id)]?.change.version
    }

    /// Сколько раз клиент загружал чек (`PUT /v1/receipts/<sha>`).
    var receiptUploadCount: Int {
        requests.filter { $0.method == "PUT" && $0.path.hasPrefix(APIPath.receipts + "/") }.count
    }

    /// Сколько раз клиент скачивал чек (`GET /v1/receipts/<sha>`).
    var receiptDownloadCount: Int {
        requests.filter { $0.method == "GET" && $0.path.hasPrefix(APIPath.receipts + "/") }.count
    }

    /// Скачивание чека (`GET /v1/receipts/<sha>`) встанет на барьер, пока тест не вызовет `releaseReceiptDownloads`.
    func blockReceiptDownloads() { downloadsBlocked = true }

    func releaseReceiptDownloads() {
        downloadsBlocked = false
        let waiting = blockedDownloads
        blockedDownloads = []
        for continuation in waiting { continuation.resume() }
    }

    /// Возвращается, когда хотя бы одно скачивание чека стоит на барьере.
    func waitForBlockedDownload() async {
        if !blockedDownloads.isEmpty { return }
        await withCheckedContinuation { blockedDownloadWaiters.append($0) }
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
            if downloadsBlocked {
                await withCheckedContinuation { continuation in
                    blockedDownloads.append(continuation)
                    let waiting = blockedDownloadWaiters
                    blockedDownloadWaiters = []
                    for waiter in waiting { waiter.resume() }
                }
            }
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
        let newer = rows.values.map(\.change).filter { $0.version > after }.sorted { $0.version < $1.version }
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
        let row = rows[key]
        // Повтор того же элемента push (тот же `changeID`) — `applied` с версией строки, как в `ChangeWriter.process`.
        if let row, row.lastChangeID == change.changeID { return .applied(version: row.change.version) }
        switch change.operation {
        case .upsert(let payload): return upsert(payload, change: change, key: key, row: row)
        case .delete(let kind, let id): return delete(kind, id: id, change: change, row: row)
        }
    }

    private func upsert(_ payload: EntityPayload, change: PushChange, key: Key, row: Row?) -> PushOutcome {
        if let existing = row?.change {
            if existing.operation.isDelete { return .conflict(reason: .deleted, current: existing) }
            if change.baseVersion == nil { return .conflict(reason: .alreadyExists, current: existing) }
            if change.baseVersion != existing.version { return .conflict(reason: .versionMismatch, current: existing) }
        } else if change.baseVersion != nil {
            return .rejected(APIError(code: .validationFailed, message: "unknown base version"))
        }
        var ownerID: UUID?
        if case .serviceRecord(let record) = payload {
            guard rows[Key(kind: .vehicle, id: record.vehicleID)].map({ !$0.change.operation.isDelete }) == true else {
                return .rejected(APIError(code: .vehicleNotFound, message: "no vehicle"))
            }
            if let receipt = record.receipt, blobs[receipt.sha256] == nil {
                return .rejected(APIError(code: .receiptNotFound, message: "no blob"))
            }
            ownerID = record.vehicleID
        }
        let version = nextVersion()
        rows[key] = Row(
            change: ServerChange(version: version, modifiedAt: change.modifiedAt, operation: change.operation),
            vehicleID: ownerID, lastChangeID: change.changeID)
        return .applied(version: version)
    }

    /// Как `ChangeWriter.delete`: `baseVersion` не проверяется, конфликтов нет. Строки нет — tombstone без
    /// владельца; строка уже tombstone — её версия; иначе tombstone строки и (для машины) всех её живых
    /// записей, по порядку версий, каждая со своей новой версией, тем же `modifiedAt` и `changeID`.
    private func delete(_ kind: EntityKind, id: UUID, change: PushChange, row: Row?) -> PushOutcome {
        let key = Key(kind: kind, id: id)
        guard let row else {
            let version = nextVersion()
            rows[key] = Row(
                change: ServerChange(version: version, modifiedAt: change.modifiedAt, operation: change.operation),
                vehicleID: nil, lastChangeID: change.changeID)
            return .applied(version: version)
        }
        if row.change.operation.isDelete { return .applied(version: row.change.version) }

        let version = nextVersion()
        tombstone(key, version: version, change: change)
        if kind == .vehicle {
            let records =
                rows
                .filter {
                    $0.key.kind == .serviceRecord && $0.value.vehicleID == id && !$0.value.change.operation.isDelete
                }
                .sorted { $0.value.change.version < $1.value.change.version }
            for (recordKey, _) in records {
                tombstone(recordKey, version: nextVersion(), change: change)
            }
        }
        return .applied(version: version)
    }

    private func tombstone(_ key: Key, version: Int64, change: PushChange) {
        // `vehicleID` строки сохраняется, как у `ChangeWriter.tombstone`.
        rows[key]?.change = ServerChange(
            version: version, modifiedAt: change.modifiedAt, operation: .delete(key.kind, id: key.id))
        rows[key]?.lastChangeID = change.changeID
    }

    private func nextVersion() -> Int64 {
        lastVersion += 1
        return lastVersion
    }
}

extension ChangeOperation {
    fileprivate var isDelete: Bool {
        if case .delete = self { true } else { false }
    }
}
