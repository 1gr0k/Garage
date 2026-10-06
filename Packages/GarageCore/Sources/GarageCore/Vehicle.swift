import Foundation

/// What sort of vehicle a `Vehicle` is.
public enum VehicleKind: String, CaseIterable, Hashable, Sendable, Codable {
    case car
    case motorcycle
    case bicycle
}

/// A single piece of equipment kept in the garage.
public struct Vehicle: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var kind: VehicleKind
    public var make: String
    public var model: String
    public var year: Int
    /// Current odometer reading, in kilometres.
    public private(set) var mileageKm: Int

    public init(
        id: UUID = UUID(),
        kind: VehicleKind,
        make: String,
        model: String,
        year: Int,
        mileageKm: Int
    ) throws(ValidationError) {
        guard mileageKm >= 0 else { throw .negativeMileage(mileageKm) }
        self.id = id
        self.kind = kind
        self.make = make
        self.model = model
        self.year = year
        self.mileageKm = mileageKm
    }

    public var displayName: String {
        "\(make) \(model)"
    }

    /// Sets a new odometer reading, enforcing the same invariant as `init`.
    public mutating func updateMileage(_ mileageKm: Int) throws(ValidationError) {
        guard mileageKm >= 0 else { throw .negativeMileage(mileageKm) }
        self.mileageKm = mileageKm
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, make, model, year, mileageKm
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            kind: container.decode(VehicleKind.self, forKey: .kind),
            make: container.decode(String.self, forKey: .make),
            model: container.decode(String.self, forKey: .model),
            year: container.decode(Int.self, forKey: .year),
            mileageKm: container.decode(Int.self, forKey: .mileageKm)
        )
    }
}

extension Vehicle {
    public static let samples: [Vehicle] = [
        try! Vehicle(kind: .car, make: "Toyota", model: "Land Cruiser", year: 2019, mileageKm: 87_400),
        try! Vehicle(kind: .car, make: "Volkswagen", model: "Transporter", year: 2015, mileageKm: 214_000),
        try! Vehicle(kind: .motorcycle, make: "Honda", model: "CB500X", year: 2021, mileageKm: 18_250),
        try! Vehicle(kind: .bicycle, make: "Specialized", model: "Rockhopper", year: 2022, mileageKm: 3_120),
    ]
}
