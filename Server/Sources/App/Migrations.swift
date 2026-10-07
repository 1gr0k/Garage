import Fluent
import FluentSQL

struct CreateDevices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Device.schema)
            .id()
            .field("name", .string, .required)
            .field("token_hash", .string, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Device.schema).delete()
    }
}

struct CreateCounter: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Counter.schema)
            .field("id", .int, .identifier(auto: false))
            .field("value", .int64, .required)
            .create()
        try await Counter(value: 0).create(on: database)
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Counter.schema).delete()
    }
}

struct CreateEntities: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(EntityRow.schema)
            .id()
            .field("kind", .string, .required)
            .field("entity_id", .uuid, .required)
            .field("vehicle_id", .uuid)
            .field("version", .int64, .required)
            .field("modified_at_ms", .int64, .required)
            .field("deleted", .bool, .required)
            .field("last_change_id", .uuid, .required)
            .field("data", .data)
            .unique(on: "kind", "entity_id")
            .create()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX entities_version ON entities (version)").run()
            try await sql.raw("CREATE INDEX entities_vehicle_id ON entities (vehicle_id)").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(EntityRow.schema).delete()
    }
}

struct CreateReceipts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Receipt.schema)
            .field("sha256", .string, .identifier(auto: false))
            .field("byte_count", .int, .required)
            .field("bytes", .data, .required)
            .field("created_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Receipt.schema).delete()
    }
}
