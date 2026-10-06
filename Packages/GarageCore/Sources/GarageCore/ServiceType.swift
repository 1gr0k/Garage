import Foundation

/// The kind of work done during a service.
///
/// Encoded as a single JSON string: simple cases use their name (`"oilChange"`),
/// `.other(text)` is encoded as `"other:<text>"`. This format is persisted, so do not rename cases.
public enum ServiceType: Hashable, Sendable {
    case oilChange
    case filters
    case tires
    case brakes
    case chain
    case suspension
    /// Scheduled maintenance (ТО).
    case inspection
    case repair
    case other(String)
}

extension ServiceType: Codable {
    private static let otherPrefix = "other:"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if string.hasPrefix(Self.otherPrefix) {
            self = .other(String(string.dropFirst(Self.otherPrefix.count)))
            return
        }
        switch string {
        case "oilChange": self = .oilChange
        case "filters": self = .filters
        case "tires": self = .tires
        case "brakes": self = .brakes
        case "chain": self = .chain
        case "suspension": self = .suspension
        case "inspection": self = .inspection
        case "repair": self = .repair
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown service type \"\(string)\""
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encodedString)
    }

    private var encodedString: String {
        switch self {
        case .oilChange: "oilChange"
        case .filters: "filters"
        case .tires: "tires"
        case .brakes: "brakes"
        case .chain: "chain"
        case .suspension: "suspension"
        case .inspection: "inspection"
        case .repair: "repair"
        case .other(let text): Self.otherPrefix + text
        }
    }
}
