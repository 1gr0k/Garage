import Fluent
import Foundation
import GarageAPI

/// The latest state of a synced entity: a live upsert (`data != nil`) or a tombstone.
final class EntityRow: Model, @unchecked Sendable {
    static let schema = "entities"

    @ID(key: .id) var id: UUID?
    @Field(key: "kind") var kind: String
    @Field(key: "entity_id") var entityID: UUID
    /// Owning vehicle of a service record: used for the delete cascade.
    @OptionalField(key: "vehicle_id") var vehicleID: UUID?
    @Field(key: "version") var version: Int64
    /// Exact milliseconds since 1970, so the value survives the exchange unchanged.
    @Field(key: "modified_at_ms") var modifiedAtMs: Int64
    @Field(key: "deleted") var deleted: Bool
    @Field(key: "last_change_id") var lastChangeID: UUID
    /// The DTO as JSON (`APICoding`); `nil` for a tombstone.
    @OptionalField(key: "data") var data: Data?

    init() {}

    init(
        kind: EntityKind, entityID: UUID, vehicleID: UUID?, version: Int64, modifiedAt: Date,
        deleted: Bool, lastChangeID: UUID, data: Data?
    ) {
        self.kind = kind.rawValue
        self.entityID = entityID
        self.vehicleID = vehicleID
        self.version = version
        self.modifiedAtMs = Self.milliseconds(modifiedAt)
        self.deleted = deleted
        self.lastChangeID = lastChangeID
        self.data = data
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    var modifiedAt: Date {
        Date(timeIntervalSince1970: Double(modifiedAtMs) / 1000)
    }

    /// The wire form of this row.
    func toServerChange() throws -> ServerChange {
        guard let entityKind = EntityKind(rawValue: kind) else { throw ServerError.internalError }
        guard !deleted else {
            return ServerChange(version: version, modifiedAt: modifiedAt, operation: .delete(entityKind, id: entityID))
        }
        guard let data else { throw ServerError.internalError }
        let decoder = APICoding.makeDecoder()
        let payload: EntityPayload =
            switch entityKind {
            case .vehicle: .vehicle(try decoder.decode(VehicleDTO.self, from: data))
            case .serviceRecord: .serviceRecord(try decoder.decode(ServiceRecordDTO.self, from: data))
            }
        return ServerChange(version: version, modifiedAt: modifiedAt, operation: .upsert(payload))
    }
}
