import Foundation
import SwiftData

@Model
public final class VehicleEntity {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var make: String
    public var model: String
    public var year: Int
    public var mileageKm: Int
    @Relationship(deleteRule: .cascade, inverse: \ServiceRecordEntity.vehicle)
    public var serviceRecords: [ServiceRecordEntity] = []

    init(
        id: UUID,
        kindRaw: String,
        make: String,
        model: String,
        year: Int,
        mileageKm: Int
    ) {
        self.id = id
        self.kindRaw = kindRaw
        self.make = make
        self.model = model
        self.year = year
        self.mileageKm = mileageKm
    }
}
