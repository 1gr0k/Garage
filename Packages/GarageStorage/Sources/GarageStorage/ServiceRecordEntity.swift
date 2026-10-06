import Foundation
import SwiftData

@Model
public final class ServiceRecordEntity {
    @Attribute(.unique) public var id: UUID
    public var vehicle: VehicleEntity?
    public var date: Date
    public var mileageKm: Int
    public var serviceTypeRaw: String
    public var laborCostKopecks: Int
    public var notes: String
    @Relationship(deleteRule: .cascade, inverse: \PartEntity.record)
    public var parts: [PartEntity] = []

    init(
        id: UUID,
        vehicle: VehicleEntity?,
        date: Date,
        mileageKm: Int,
        serviceTypeRaw: String,
        laborCostKopecks: Int,
        notes: String
    ) {
        self.id = id
        self.vehicle = vehicle
        self.date = date
        self.mileageKm = mileageKm
        self.serviceTypeRaw = serviceTypeRaw
        self.laborCostKopecks = laborCostKopecks
        self.notes = notes
    }
}
