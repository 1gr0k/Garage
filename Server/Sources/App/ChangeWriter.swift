import Fluent
import Foundation
import GarageAPI
import Vapor

/// The only writer of entity rows and the version counter.
///
/// Versions must be allocated *and committed* in order, otherwise a pull could skip a version that
/// commits later than a bigger one. Every push item runs as one transaction on this actor, and the next
/// item starts only after the previous one has committed. This relies on a single server process:
/// a second process on the same database would break the ordering.
actor ChangeWriter {
    private let database: any Database
    private let logger: Logger

    init(database: any Database, logger: Logger) {
        self.database = database
        self.logger = logger
    }

    func apply(_ change: PushChange) async -> PushResult {
        do {
            let outcome = try await database.transaction { transaction in
                try await Self.process(change, on: transaction)
            }
            return PushResult(changeID: change.changeID, outcome: outcome)
        } catch {
            logger.error("Push item \(change.changeID) failed: \(String(reflecting: error))")
            return PushResult(
                changeID: change.changeID,
                outcome: .rejected(ServerError.internalError.api))
        }
    }

    // MARK: - Processing

    private static func process(_ change: PushChange, on db: any Database) async throws -> PushOutcome {
        let (kind, id): (EntityKind, UUID) =
            switch change.operation {
            case .upsert(let payload): (payload.kind, payload.id)
            case .delete(let kind, let id): (kind, id)
            }
        let row = try await EntityRow.query(on: db)
            .filter(\.$kind == kind.rawValue)
            .filter(\.$entityID == id)
            .first()

        if let row, row.lastChangeID == change.changeID {
            return .applied(version: row.version)
        }
        switch change.operation {
        case .upsert(let payload):
            return try await upsert(payload, change: change, row: row, on: db)
        case .delete(let kind, let id):
            return try await delete(kind, id: id, change: change, row: row, on: db)
        }
    }

    private static func upsert(
        _ payload: EntityPayload, change: PushChange, row: EntityRow?, on db: any Database
    ) async throws -> PushOutcome {
        do {
            try DTOValidation.validate(payload)
        } catch {
            return .rejected(APIError(code: .validationFailed, message: error.message))
        }

        if let row {
            if row.deleted {
                return .conflict(reason: .deleted, current: try row.toServerChange())
            }
            guard let baseVersion = change.baseVersion else {
                return .conflict(reason: .alreadyExists, current: try row.toServerChange())
            }
            guard baseVersion == row.version else {
                return .conflict(reason: .versionMismatch, current: try row.toServerChange())
            }
        }

        var ownerID: UUID?
        let encoder = APICoding.makeEncoder()
        let data: Data
        switch payload {
        case .vehicle(let dto):
            data = try encoder.encode(dto)
        case .maintenanceRule(let dto):
            if let rejection = try await requireLiveVehicle(dto.vehicleID, on: db) { return rejection }
            ownerID = dto.vehicleID
            data = try encoder.encode(dto)
        case .serviceRecord(let dto):
            if let rejection = try await requireLiveVehicle(dto.vehicleID, on: db) { return rejection }
            if let receipt = dto.receipt {
                let exists = try await Receipt.find(receipt.sha256, on: db) != nil
                guard exists else {
                    return .rejected(
                        APIError(code: .receiptNotFound, message: "Receipt \(receipt.sha256) does not exist"))
                }
            }
            ownerID = dto.vehicleID
            data = try encoder.encode(dto)
        }

        let version = try await nextVersion(on: db)
        let target =
            row
            ?? EntityRow(
                kind: payload.kind, entityID: payload.id, vehicleID: ownerID, version: version,
                modifiedAt: change.modifiedAt, deleted: false, lastChangeID: change.changeID, data: data)
        target.vehicleID = ownerID
        target.version = version
        target.modifiedAtMs = EntityRow.milliseconds(change.modifiedAt)
        target.deleted = false
        target.lastChangeID = change.changeID
        target.data = data
        try await target.save(on: db)
        return .applied(version: version)
    }

    /// Дочерняя сущность (запись, правило) принимается только к существующей, не удалённой машине.
    private static func requireLiveVehicle(_ vehicleID: UUID, on db: any Database) async throws -> PushOutcome? {
        let vehicle = try await EntityRow.query(on: db)
            .filter(\.$kind == EntityKind.vehicle.rawValue)
            .filter(\.$entityID == vehicleID)
            .filter(\.$deleted == false)
            .first()
        guard vehicle != nil else {
            return .rejected(
                APIError(code: .vehicleNotFound, message: "Vehicle \(vehicleID.uuidString) does not exist"))
        }
        return nil
    }

    private static func delete(
        _ kind: EntityKind, id: UUID, change: PushChange, row: EntityRow?, on db: any Database
    ) async throws -> PushOutcome {
        guard let row else {
            let version = try await nextVersion(on: db)
            try await EntityRow(
                kind: kind, entityID: id, vehicleID: nil, version: version, modifiedAt: change.modifiedAt,
                deleted: true, lastChangeID: change.changeID, data: nil
            ).create(on: db)
            return .applied(version: version)
        }
        if row.deleted {
            return .applied(version: row.version)
        }

        let version = try await nextVersion(on: db)
        try await tombstone(row, version: version, change: change, on: db)

        if kind == .vehicle {
            // Каскад: tombstone каждой живой дочерней сущности машины (записи и правила), по возрастанию версии.
            let children = try await EntityRow.query(on: db)
                .filter(\.$kind ~~ EntityKind.allCases.filter(\.isVehicleChild).map(\.rawValue))
                .filter(\.$vehicleID == id)
                .filter(\.$deleted == false)
                .sort(\.$version)
                .all()
            for child in children {
                try await tombstone(child, version: try await nextVersion(on: db), change: change, on: db)
            }
        }
        return .applied(version: version)
    }

    private static func tombstone(
        _ row: EntityRow, version: Int64, change: PushChange, on db: any Database
    ) async throws {
        row.version = version
        row.modifiedAtMs = EntityRow.milliseconds(change.modifiedAt)
        row.deleted = true
        row.lastChangeID = change.changeID
        row.data = nil
        try await row.update(on: db)
    }

    private static func nextVersion(on db: any Database) async throws -> Int64 {
        guard let counter = try await Counter.find(Counter.rowID, on: db) else { throw ServerError.internalError }
        counter.value += 1
        try await counter.update(on: db)
        return counter.value
    }
}

private struct ChangeWriterKey: StorageKey {
    typealias Value = ChangeWriter
}

extension Application {
    var changeWriter: ChangeWriter {
        get { storage[ChangeWriterKey.self]! }
        set { storage[ChangeWriterKey.self] = newValue }
    }
}
