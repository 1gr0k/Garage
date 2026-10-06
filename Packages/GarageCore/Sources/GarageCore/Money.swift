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

    /// Parses user input such as `"1 250,50"`, `"99.9"` or `"700"`.
    ///
    /// All whitespace (including U+00A0 and U+202F) is ignored. The fraction separator is `,` or `.`
    /// with at most two digits after it. Signs, letters and empty input are rejected.
    public init(parsing text: String) throws(ValidationError) {
        let compact = String(text.filter { !$0.isWhitespace })
        let parts = compact.split(separator: /[.,]/, maxSplits: 1, omittingEmptySubsequences: false)
        guard let wholePart = parts.first, parts.count <= 2,
            Self.isDigits(wholePart),
            let rubles = Int(wholePart)
        else { throw .invalidAmount(text) }

        var kopecks = 0
        if parts.count == 2 {
            let fraction = parts[1]
            guard Self.isDigits(fraction), fraction.count <= 2, let value = Int(fraction) else {
                throw .invalidAmount(text)
            }
            kopecks = fraction.count == 1 ? value * 10 : value
        }
        let (scaled, overflow) = rubles.multipliedReportingOverflow(by: 100)
        guard !overflow, scaled <= Int.max - kopecks else { throw .invalidAmount(text) }
        self.kopecks = scaled + kopecks
    }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
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
