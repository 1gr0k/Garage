import Fluent
import FluentSQL
import FluentSQLiteDriver
import Foundation
import GarageAPI
import Vapor

public struct ServerConfiguration: Sendable {
    public enum Storage: Sendable {
        case file(String)
        case memory
    }

    public var storage: Storage
    public var setupSecret: String

    public init(storage: Storage, setupSecret: String) {
        self.storage = storage
        self.setupSecret = setupSecret
    }

    struct MissingVariable: Error, CustomStringConvertible {
        var name: String
        var description: String { "Environment variable \(name) is required and must not be empty" }
    }

    /// Reads `GARAGE_DB_PATH` and `GARAGE_SETUP_SECRET`; both are required.
    public static func fromEnvironment() throws -> ServerConfiguration {
        func required(_ name: String) throws -> String {
            guard let value = Environment.get(name), !value.isEmpty else { throw MissingVariable(name: name) }
            return value
        }
        return ServerConfiguration(
            storage: .file(try required("GARAGE_DB_PATH")),
            setupSecret: try required("GARAGE_SETUP_SECRET"))
    }
}

struct SetupSecretKey: StorageKey {
    typealias Value = String
}

extension Application {
    var setupSecret: String {
        get { storage[SetupSecretKey.self]! }
        set { storage[SetupSecretKey.self] = newValue }
    }
}

public func configure(_ app: Application, configuration: ServerConfiguration? = nil) async throws {
    let configuration = try configuration ?? ServerConfiguration.fromEnvironment()
    guard !configuration.setupSecret.isEmpty else {
        throw ServerConfiguration.MissingVariable(name: "GARAGE_SETUP_SECRET")
    }
    app.setupSecret = configuration.setupSecret

    ContentConfiguration.global.use(encoder: APICoding.makeEncoder(), for: .json)
    ContentConfiguration.global.use(decoder: APICoding.makeDecoder(), for: .json)

    // A full push batch (100 records with parts) is far above Vapor's 16 KB default.
    app.routes.defaultMaxBodySize = "2mb"
    app.middleware = Middlewares()
    app.middleware.use(APIErrorMiddleware())

    switch configuration.storage {
    case .file(let path): app.databases.use(.sqlite(.file(path)), as: .sqlite)
    case .memory: app.databases.use(.sqlite(.memory), as: .sqlite)
    }
    app.migrations.add(CreateDevices(), CreateCounter(), CreateEntities(), CreateReceipts())
    try await app.autoMigrate()

    if case .file = configuration.storage, let sql = app.db as? any SQLDatabase {
        // Persistent in the database file: readers do not block the writer.
        try await sql.raw("PRAGMA journal_mode=WAL").run()
    }

    app.changeWriter = ChangeWriter(database: app.db, logger: app.logger)
    try routes(app)
}
