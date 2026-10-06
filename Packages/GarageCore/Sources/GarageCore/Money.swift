import Foundation

/// An amount in Russian rubles, stored as a whole number of kopecks to keep arithmetic exact.
public struct Money: Hashable, Sendable, Comparable, AdditiveArithmetic {
    public var kopecks: Int

    public init(kopecks: Int) {
        self.kopecks = kopecks
    }

    public init(rubles: Int, kopecks: Int = 0) {
        self.kopecks = rubles * 100 + kopecks
    }

    public static let zero = Money(kopecks: 0)

    public static func + (lhs: Money, rhs: Money) -> Money {
        Money(kopecks: lhs.kopecks + rhs.kopecks)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        Money(kopecks: lhs.kopecks - rhs.kopecks)
    }

    public static func * (lhs: Money, rhs: Int) -> Money {
        Money(kopecks: lhs.kopecks * rhs)
    }

    public static func < (lhs: Money, rhs: Money) -> Bool {
        lhs.kopecks < rhs.kopecks
    }
}

extension Money: Codable {
    public init(from decoder: any Decoder) throws {
        kopecks = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(kopecks)
    }
}
