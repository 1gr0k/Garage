import Foundation

public enum EntityKind: String, Hashable, Sendable, Codable {
    case vehicle
    case serviceRecord
}

/// Full state of a synced entity (upsert never carries a patch).
public enum EntityPayload: Hashable, Sendable {
    case vehicle(VehicleDTO)
    case serviceRecord(ServiceRecordDTO)

    public var kind: EntityKind {
        switch self {
        case .vehicle: .vehicle
        case .serviceRecord: .serviceRecord
        }
    }

    public var id: UUID {
        switch self {
        case .vehicle(let dto): dto.id
        case .serviceRecord(let dto): dto.id
        }
    }
}

/// `{"op":"upsert","entity":…,"data":{…}}` or `{"op":"delete","entity":…,"id":…}`.
public enum ChangeOperation: Hashable, Sendable {
    case upsert(EntityPayload)
    case delete(EntityKind, id: UUID)
}

/// Keys shared by every type that flattens a `ChangeOperation` into its own object.
private enum ChangeKeys: String, CodingKey {
    case version, modifiedAt, changeID, baseVersion
    case op, entity, data, id
}

extension ChangeOperation {
    fileprivate func encode(into container: inout KeyedEncodingContainer<ChangeKeys>) throws {
        switch self {
        case .upsert(let payload):
            try container.encode("upsert", forKey: .op)
            try container.encode(payload.kind, forKey: .entity)
            switch payload {
            case .vehicle(let dto): try container.encode(dto, forKey: .data)
            case .serviceRecord(let dto): try container.encode(dto, forKey: .data)
            }
        case .delete(let kind, let id):
            try container.encode("delete", forKey: .op)
            try container.encode(kind, forKey: .entity)
            try container.encode(id, forKey: .id)
        }
    }

    fileprivate init(from container: KeyedDecodingContainer<ChangeKeys>) throws {
        let op = try container.decode(String.self, forKey: .op)
        let entityString = try container.decode(String.self, forKey: .entity)
        guard let kind = EntityKind(rawValue: entityString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .entity, in: container, debugDescription: "Unknown entity \"\(entityString)\"")
        }
        switch op {
        case "upsert":
            switch kind {
            case .vehicle:
                self = .upsert(.vehicle(try container.decode(VehicleDTO.self, forKey: .data)))
            case .serviceRecord:
                self = .upsert(.serviceRecord(try container.decode(ServiceRecordDTO.self, forKey: .data)))
            }
        case "delete":
            self = .delete(kind, id: try container.decode(UUID.self, forKey: .id))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: container, debugDescription: "Unknown op \"\(op)\"")
        }
    }
}

extension ChangeOperation: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(from: try decoder.container(keyedBy: ChangeKeys.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ChangeKeys.self)
        try encode(into: &container)
    }
}

/// A change as stored on the server: its version, the device edit time and the operation.
public struct ServerChange: Hashable, Sendable, Codable {
    public var version: Int64
    public var modifiedAt: Date
    public var operation: ChangeOperation

    public init(version: Int64, modifiedAt: Date, operation: ChangeOperation) {
        self.version = version
        self.modifiedAt = modifiedAt
        self.operation = operation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ChangeKeys.self)
        version = try container.decode(Int64.self, forKey: .version)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        operation = try ChangeOperation(from: container)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ChangeKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try operation.encode(into: &container)
    }
}

/// `GET /v1/changes` response. `cursor` is opaque.
public struct PullResponse: Hashable, Sendable, Codable {
    public var changes: [ServerChange]
    public var cursor: String
    public var hasMore: Bool

    public init(changes: [ServerChange], cursor: String, hasMore: Bool) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

/// A change pushed by a device. `baseVersion == nil` means creation; `changeID` makes the push idempotent.
public struct PushChange: Hashable, Sendable, Codable {
    public var changeID: UUID
    public var baseVersion: Int64?
    public var modifiedAt: Date
    public var operation: ChangeOperation

    public init(changeID: UUID, baseVersion: Int64?, modifiedAt: Date, operation: ChangeOperation) {
        self.changeID = changeID
        self.baseVersion = baseVersion
        self.modifiedAt = modifiedAt
        self.operation = operation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ChangeKeys.self)
        changeID = try container.decode(UUID.self, forKey: .changeID)
        baseVersion = try container.decodeIfPresent(Int64.self, forKey: .baseVersion)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        operation = try ChangeOperation(from: container)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ChangeKeys.self)
        try container.encode(changeID, forKey: .changeID)
        try container.encodeIfPresent(baseVersion, forKey: .baseVersion)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try operation.encode(into: &container)
    }
}

/// `POST /v1/changes` body (at most `APIPath.maxPushBatch` items, processed in order).
public struct PushRequest: Hashable, Sendable, Codable {
    public var changes: [PushChange]

    public init(changes: [PushChange]) {
        self.changes = changes
    }
}

/// Why a push item conflicted. Unknown reasons decode to `.unknown`: the client resolves them
/// from `current` like any other conflict, so new reasons are a compatible change.
public enum ConflictReason: Hashable, Sendable {
    case versionMismatch
    case deleted
    case alreadyExists
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .versionMismatch: "versionMismatch"
        case .deleted: "deleted"
        case .alreadyExists: "alreadyExists"
        case .unknown(let value): value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "versionMismatch": self = .versionMismatch
        case "deleted": self = .deleted
        case "alreadyExists": self = .alreadyExists
        default: self = .unknown(rawValue)
        }
    }
}

extension ConflictReason: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum PushOutcome: Hashable, Sendable {
    case applied(version: Int64)
    case conflict(reason: ConflictReason, current: ServerChange)
    case rejected(APIError)
}

/// Result of one pushed item, correlated by `changeID`.
public struct PushResult: Hashable, Sendable, Codable {
    public var changeID: UUID
    public var outcome: PushOutcome

    public init(changeID: UUID, outcome: PushOutcome) {
        self.changeID = changeID
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case changeID, status, version, reason, current, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changeID = try container.decode(UUID.self, forKey: .changeID)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "applied":
            outcome = .applied(version: try container.decode(Int64.self, forKey: .version))
        case "conflict":
            outcome = .conflict(
                reason: try container.decode(ConflictReason.self, forKey: .reason),
                current: try container.decode(ServerChange.self, forKey: .current))
        case "rejected":
            outcome = .rejected(try container.decode(APIError.self, forKey: .error))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status, in: container, debugDescription: "Unknown status \"\(status)\"")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(changeID, forKey: .changeID)
        switch outcome {
        case .applied(let version):
            try container.encode("applied", forKey: .status)
            try container.encode(version, forKey: .version)
        case .conflict(let reason, let current):
            try container.encode("conflict", forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encode(current, forKey: .current)
        case .rejected(let error):
            try container.encode("rejected", forKey: .status)
            try container.encode(error, forKey: .error)
        }
    }
}

/// `200` response of `POST /v1/changes`: one result per request item, in order.
public struct PushResponse: Hashable, Sendable, Codable {
    public var results: [PushResult]

    public init(results: [PushResult]) {
        self.results = results
    }
}
