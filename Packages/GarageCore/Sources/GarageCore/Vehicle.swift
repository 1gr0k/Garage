import Foundation

/// A single piece of equipment kept in the garage.
public struct Vehicle: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var make: String
    public var model: String
    public var year: Int

    public init(id: UUID = UUID(), make: String, model: String, year: Int) {
        self.id = id
        self.make = make
        self.model = model
        self.year = year
    }

    public var displayName: String {
        "\(make) \(model)"
    }
}

extension Vehicle {
    public static let samples: [Vehicle] = [
        Vehicle(make: "Toyota", model: "Land Cruiser", year: 2019),
        Vehicle(make: "Volkswagen", model: "Transporter", year: 2015),
        Vehicle(make: "Honda", model: "CB500X", year: 2021),
        Vehicle(make: "John Deere", model: "5075E", year: 2018),
    ]
}
