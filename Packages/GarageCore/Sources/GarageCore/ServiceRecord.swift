import Foundation

/// One entry in a vehicle's service log.
public struct ServiceRecord: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var vehicleID: Vehicle.ID
    public var date: Date
    /// Odometer reading at the time of the service, in kilometres.
    public private(set) var mileageKm: Int
    public var serviceType: ServiceType
    /// Cost of the work itself, excluding parts.
    public var laborCost: Money
    public var notes: String
    public var parts: [Part]

    public init(
        id: UUID = UUID(),
        vehicleID: Vehicle.ID,
        date: Date,
        mileageKm: Int,
        serviceType: ServiceType,
        laborCost: Money,
        notes: String = "",
        parts: [Part] = []
    ) throws(ValidationError) {
        guard mileageKm >= 0 else { throw .negativeMileage(mileageKm) }
        self.id = id
        self.vehicleID = vehicleID
        self.date = date
        self.mileageKm = mileageKm
        self.serviceType = serviceType
        self.laborCost = laborCost
        self.notes = notes
        self.parts = parts
    }

    /// Sets a new odometer reading, enforcing the same invariant as `init`.
    public mutating func updateMileage(_ mileageKm: Int) throws(ValidationError) {
        guard mileageKm >= 0 else { throw .negativeMileage(mileageKm) }
        self.mileageKm = mileageKm
    }

    public var partsCost: Money {
        parts.reduce(.zero) { $0 + $1.totalPrice }
    }

    public var totalCost: Money {
        laborCost + partsCost
    }

    private enum CodingKeys: String, CodingKey {
        case id, vehicleID, date, mileageKm, serviceType, laborCost, notes, parts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            vehicleID: container.decode(UUID.self, forKey: .vehicleID),
            date: container.decode(Date.self, forKey: .date),
            mileageKm: container.decode(Int.self, forKey: .mileageKm),
            serviceType: container.decode(ServiceType.self, forKey: .serviceType),
            laborCost: container.decode(Money.self, forKey: .laborCost),
            notes: container.decode(String.self, forKey: .notes),
            parts: container.decode([Part].self, forKey: .parts)
        )
    }
}
