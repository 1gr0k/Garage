import Foundation

/// A part or consumable used during a service.
public struct Part: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public private(set) var name: String
    /// Manufacturer part number (артикул), if known.
    public var partNumber: String?
    public private(set) var unitPrice: Money
    public private(set) var quantity: Int

    public init(
        id: UUID = UUID(),
        name: String,
        partNumber: String? = nil,
        unitPrice: Money,
        quantity: Int = 1
    ) throws(ValidationError) {
        try Self.validate(name: name)
        try Self.validate(unitPrice: unitPrice)
        guard quantity > 0 else { throw .nonPositiveQuantity(quantity) }
        self.id = id
        self.name = name
        self.partNumber = partNumber
        self.unitPrice = unitPrice
        self.quantity = quantity
    }

    /// Sets a new name, enforcing the same invariant as `init`.
    public mutating func updateName(_ name: String) throws(ValidationError) {
        try Self.validate(name: name)
        self.name = name
    }

    /// Sets a new unit price, enforcing the same invariant as `init`.
    public mutating func updateUnitPrice(_ unitPrice: Money) throws(ValidationError) {
        try Self.validate(unitPrice: unitPrice)
        self.unitPrice = unitPrice
    }

    private static func validate(name: String) throws(ValidationError) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .emptyPartName }
    }

    private static func validate(unitPrice: Money) throws(ValidationError) {
        guard unitPrice >= .zero else { throw .negativeAmount(unitPrice) }
    }

    /// Sets a new quantity, enforcing the same invariant as `init`.
    public mutating func updateQuantity(_ quantity: Int) throws(ValidationError) {
        guard quantity > 0 else { throw .nonPositiveQuantity(quantity) }
        self.quantity = quantity
    }

    public var totalPrice: Money {
        unitPrice * quantity
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, partNumber, unitPrice, quantity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            partNumber: container.decodeIfPresent(String.self, forKey: .partNumber),
            unitPrice: container.decode(Money.self, forKey: .unitPrice),
            quantity: container.decode(Int.self, forKey: .quantity)
        )
    }
}
