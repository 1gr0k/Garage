import Foundation
import GarageAPI
import GarageCore

public struct EntityRef: Hashable, Sendable {
    public var kind: EntityKind
    public var id: UUID

    public init(kind: EntityKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

/// The full state of a synced entity in domain terms.
public enum SyncEntity: Hashable, Sendable {
    case vehicle(Vehicle)
    case serviceRecord(ServiceRecord, RecordSyncExtras)

    public var ref: EntityRef {
        switch self {
        case .vehicle(let vehicle): EntityRef(kind: .vehicle, id: vehicle.id)
        case .serviceRecord(let record, _): EntityRef(kind: .serviceRecord, id: record.id)
        }
    }

    public var payload: EntityPayload {
        switch self {
        case .vehicle(let vehicle): .vehicle(VehicleDTO(vehicle))
        case .serviceRecord(let record, let extras): .serviceRecord(ServiceRecordDTO(record, extras: extras))
        }
    }

    public init(payload: EntityPayload) throws {
        switch payload {
        case .vehicle(let dto):
            self = .vehicle(try Vehicle(dto: dto))
        case .serviceRecord(let dto):
            let (record, extras) = try ServiceRecord.decoded(from: dto)
            self = .serviceRecord(record, extras)
        }
    }
}

public enum LocalOperation: Hashable, Sendable {
    case upsert(SyncEntity)
    case delete(EntityRef)

    public var ref: EntityRef {
        switch self {
        case .upsert(let entity): entity.ref
        case .delete(let ref): ref
        }
    }

    public var isDelete: Bool {
        if case .delete = self { true } else { false }
    }

    public var changeOperation: ChangeOperation {
        switch self {
        case .upsert(let entity): .upsert(entity.payload)
        case .delete(let ref): .delete(ref.kind, id: ref.id)
        }
    }

    public init(_ operation: ChangeOperation) throws {
        switch operation {
        case .upsert(let payload): self = .upsert(try SyncEntity(payload: payload))
        case .delete(let kind, let id): self = .delete(EntityRef(kind: kind, id: id))
        }
    }
}

/// A local edit waiting to be pushed. One per entity: later edits replace earlier ones.
public struct PendingChange: Hashable, Sendable {
    public var changeID: UUID
    /// The server version the edit is based on; `nil` for creation.
    public var baseVersion: Int64?
    public var modifiedAt: Date
    public var operation: LocalOperation

    public init(changeID: UUID, baseVersion: Int64?, modifiedAt: Date, operation: LocalOperation) {
        self.changeID = changeID
        self.baseVersion = baseVersion
        // The wire format has millisecond precision; rounding here keeps the value stable across a round trip.
        self.modifiedAt = Date(timeIntervalSince1970: (modifiedAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.operation = operation
    }

    public var pushChange: PushChange {
        PushChange(
            changeID: changeID, baseVersion: baseVersion, modifiedAt: modifiedAt,
            operation: operation.changeOperation)
    }
}

/// What the store applies to local data. `version == nil` is a local-only deletion
/// (the server rejected the entity), which leaves the remembered version untouched.
public struct RemoteChange: Hashable, Sendable {
    public var version: Int64?
    public var operation: LocalOperation

    public init(version: Int64?, operation: LocalOperation) {
        self.version = version
        self.operation = operation
    }
}

extension ChangeOperation {
    var ref: EntityRef {
        switch self {
        case .upsert(let payload): EntityRef(kind: payload.kind, id: payload.id)
        case .delete(let kind, let id): EntityRef(kind: kind, id: id)
        }
    }

    var isDelete: Bool {
        if case .delete = self { true } else { false }
    }
}
