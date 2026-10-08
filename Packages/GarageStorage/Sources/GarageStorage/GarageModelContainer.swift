import Foundation
import SwiftData

public enum GarageStore {
    /// Bump on every change to `models`. When the stored value differs, the sync state is reset on open
    /// (see `SyncSupport.prepare`) so the next sync does a full download.
    /// Changes are additive for now, so there is no `SchemaMigrationPlan`.
    ///
    /// Растёт и тогда, когда клиент начал понимать новый вид сущности `EntityKind` (docs/api.md, «Правила эволюции
    /// контракта», п. 4): `ContractTripwireTests` роняет сборку, если набор видов изменился, а версия — нет.
    /// 3: вид `maintenanceRule` (заглушка в `SwiftDataSyncStore`, этап 12, часть S).
    /// 4: `MaintenanceRuleEntity` и `VehicleEntity.rawKind` (этап 12, часть B): клиент начал хранить правила и
    /// машины с незнакомым видом, пропущенные раньше; следующая синхронизация скачает всё заново.
    public static let schemaVersion = 4

    public static let models: [any PersistentModel.Type] = [
        VehicleEntity.self, ServiceRecordEntity.self, MaintenanceRuleEntity.self, PartEntity.self,
        PendingChangeEntity.self, SyncVersionEntity.self, SyncStateEntity.self,
    ]

    /// - Parameter url: файл хранилища вместо стандартного места (тесты апгрейда на файле); при `inMemory` не учитывается.
    public static func makeContainer(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration: ModelConfiguration
        if let url, !inMemory {
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
