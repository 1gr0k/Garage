import Fluent
import Foundation

/// A receipt photo stored content-addressed by the hex SHA-256 of its bytes.
final class Receipt: Model, @unchecked Sendable {
    static let schema = "receipts"

    @ID(custom: "sha256", generatedBy: .user) var id: String?
    @Field(key: "byte_count") var byteCount: Int
    @Field(key: "bytes") var bytes: Data
    @Field(key: "created_at") var createdAt: Date

    init() {}

    init(sha256: String, bytes: Data, createdAt: Date = Date()) {
        self.id = sha256
        self.byteCount = bytes.count
        self.bytes = bytes
        self.createdAt = createdAt
    }
}
