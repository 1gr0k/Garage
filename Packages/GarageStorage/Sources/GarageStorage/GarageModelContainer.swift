import SwiftData

public enum GarageStore {
    /// Bump on every change to `models`. When the stored value differs, the sync state is reset on open
    /// (see `SyncSupport.prepare`) so the next sync does a full download.
    /// Changes are additive for now, so there is no `SchemaMigrationPlan`.
    ///
    /// Растёт и тогда, когда клиент начал понимать новый вид сущности `EntityKind` (docs/api.md, «Правила эволюции
    /// контракта», п. 4): `ContractTripwireTests` роняет сборку, если набор видов изменился, а версия — нет.
    /// 3: вид `maintenanceRule` (пока заглушка в `SwiftDataSyncStore`, модель правил — этап 12, часть B).
    public static let schemaVersion = 3

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
