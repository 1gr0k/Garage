import Foundation

/// Error codes. Unknown codes decode to `.unknown`, so adding codes is a compatible change.
public enum APIErrorCode: Hashable, Sendable {
    case malformedRequest
    case unauthorized
    case invalidSetupSecret
    case notFound
    case cursorExpired
    case payloadTooLarge
    case unsupportedMediaType
    case hashMismatch
    case upgradeRequired
    case `internal`
    // Push item rejections (never an HTTP status).
    case validationFailed
    case vehicleNotFound
    case receiptNotFound
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .malformedRequest: "malformedRequest"
        case .unauthorized: "unauthorized"
        case .invalidSetupSecret: "invalidSetupSecret"
        case .notFound: "notFound"
        case .cursorExpired: "cursorExpired"
        case .payloadTooLarge: "payloadTooLarge"
        case .unsupportedMediaType: "unsupportedMediaType"
        case .hashMismatch: "hashMismatch"
        case .upgradeRequired: "upgradeRequired"
        case .internal: "internal"
        case .validationFailed: "validationFailed"
        case .vehicleNotFound: "vehicleNotFound"
        case .receiptNotFound: "receiptNotFound"
        case .unknown(let value): value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "malformedRequest": self = .malformedRequest
        case "unauthorized": self = .unauthorized
        case "invalidSetupSecret": self = .invalidSetupSecret
        case "notFound": self = .notFound
        case "cursorExpired": self = .cursorExpired
        case "payloadTooLarge": self = .payloadTooLarge
        case "unsupportedMediaType": self = .unsupportedMediaType
        case "hashMismatch": self = .hashMismatch
        case "upgradeRequired": self = .upgradeRequired
        case "internal": self = .internal
        case "validationFailed": self = .validationFailed
        case "vehicleNotFound": self = .vehicleNotFound
        case "receiptNotFound": self = .receiptNotFound
        default: self = .unknown(rawValue)
        }
    }

    /// HTTP status of request-level errors; `nil` for push item rejections and unknown codes.
    public var httpStatus: Int? {
        switch self {
        case .malformedRequest: 400
        case .unauthorized, .invalidSetupSecret: 401
        case .notFound: 404
        case .cursorExpired: 410
        case .payloadTooLarge: 413
        case .unsupportedMediaType: 415
        case .hashMismatch: 422
        case .upgradeRequired: 426
        case .internal: 500
        case .validationFailed, .vehicleNotFound, .receiptNotFound, .unknown: nil
        }
    }
}

extension APIErrorCode: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct APIError: Hashable, Sendable, Codable {
    public var code: APIErrorCode
    public var message: String
    public var details: [String: String]?

    public init(code: APIErrorCode, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

/// Body of every HTTP error response: `{"error":{…}}`.
public struct APIErrorResponse: Hashable, Sendable, Codable {
    public var error: APIError

    public init(error: APIError) {
        self.error = error
    }
}
