import Foundation

/// Shared JSON configuration of the sync API. Both client and server must use it.
///
/// Keys are camelCase (no key strategy), dates are ISO 8601 UTC with milliseconds
/// (the decoder also accepts them without the fractional part), output is key-sorted.
public enum APICoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date \"\(string)\""
            )
        }
        return decoder
    }
}

/// Paths, query parameter names and limits of API v1.
public enum APIPath {
    public static let version = "/v1"
    public static let changes = "/v1/changes"
    public static let devices = "/v1/devices"
    public static let receipts = "/v1/receipts"

    public static func receipt(sha256: String) -> String {
        "\(receipts)/\(sha256)"
    }

    public static let afterQuery = "after"
    public static let limitQuery = "limit"

    public static let maxPushBatch = 100
    public static let maxPullLimit = 500
    public static let defaultPullLimit = 200
    public static let maxReceiptBytes = 5 * 1024 * 1024
}
