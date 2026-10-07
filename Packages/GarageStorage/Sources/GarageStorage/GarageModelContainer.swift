import SwiftData

public enum GarageStore {
    /// Bump on every change to `models`. When the stored value differs, the sync state is reset on open
    /// (see `SyncSupport.prepare`) so the next sync does a full download.
    /// Changes are additive for now, so there is no `SchemaMigrationPlan`.
    public static let schemaVersion = 2

    public static let models: [any PersistentModel.Type] = [
        VehicleEntity.self, ServiceRecordEntity.self, PartEntity.self,
        PendingChangeEntity.self, SyncVersionEntity.self, SyncStateEntity.self,
    ]

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
