import Fluent
import Foundation
import Vapor

final class Device: Model, Authenticatable, @unchecked Sendable {
    static let schema = "devices"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    /// Hex SHA-256 of the token; the token itself is never stored.
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "created_at") var createdAt: Date

    init() {}

    init(id: UUID = UUID(), name: String, tokenHash: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.createdAt = createdAt
    }
}
