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

    /// The effective odometer reading: the manual value or the highest mileage among this vehicle's records.
    ///
    /// Derived rather than stored, so a mistaken record stops affecting it once it is removed.
    public func currentMileageKm(records: some Sequence<ServiceRecord>) -> Int {
        let recorded = records.lazy.filter { $0.vehicleID == id }.map(\.mileageKm).max() ?? 0
        return max(mileageKm, recorded)
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
    /// Fixed ids of `samples`: the demo vehicles are the same entities on every device that syncs.
    public enum SampleID {
        public static let landCruiser = UUID(uuidString: "5A3F0001-6C0D-4B7E-9A10-000000000001")!
        public static let transporter = UUID(uuidString: "5A3F0002-6C0D-4B7E-9A10-000000000002")!
        public static let cb500x = UUID(uuidString: "5A3F0003-6C0D-4B7E-9A10-000000000003")!
        public static let rockhopper = UUID(uuidString: "5A3F0004-6C0D-4B7E-9A10-000000000004")!
    }

    public static let samples: [Vehicle] = [
        try! Vehicle(
            id: SampleID.landCruiser, kind: .car, make: "Toyota", model: "Land Cruiser", year: 2019,
            mileageKm: 87_400),
        try! Vehicle(
            id: SampleID.transporter, kind: .car, make: "Volkswagen", model: "Transporter", year: 2015,
            mileageKm: 214_000),
        try! Vehicle(
            id: SampleID.cb500x, kind: .motorcycle, make: "Honda", model: "CB500X", year: 2021, mileageKm: 18_250),
        try! Vehicle(
            id: SampleID.rockhopper, kind: .bicycle, make: "Specialized", model: "Rockhopper", year: 2022,
            mileageKm: 3_120),
    ]
}
