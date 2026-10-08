import Foundation
import GarageCore
import SwiftData

/// `MaintenanceRuleRepository` и `MaintenanceSnapshotReading` поверх SwiftData. Очередь синхронизации ведёт `RuleLog`,
/// каскад с машиной — отношение `VehicleEntity.maintenanceRules`.
public struct SwiftDataMaintenanceRuleRepository: MaintenanceRuleRepository, MaintenanceSnapshotReading {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func add(_ rule: MaintenanceRule) async throws {
        do {
            try RuleLog.add(rule, in: container)
        } catch ServiceLogError.vehicleNotFound(let id) {
            throw RepositoryError.vehicleNotFound(id)
        }
    }

    public func update(_ rule: MaintenanceRule, period: MaintenancePeriodChange) async throws {
        do {
            try RuleLog.update(rule, period: period, in: container)
        } catch ServiceLogError.ruleNotFound(let id) {
            throw RepositoryError.ruleNotFound(id)
        }
    }

    public func delete(id: MaintenanceRule.ID) async throws {
        try RuleLog.delete(id: id, in: container)
    }

    /// Свежий контекст: снимок не зависит от несохранённых правок чужих контекстов. Нечитаемые сущности
    /// пропускаются с записью в лог, как в `DisplayMapping`.
    public func snapshot() async throws -> MaintenanceSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let vehicles = try context.fetch(FetchDescriptor<VehicleEntity>()).validVehicles().map(\.vehicle)
        let records = try context.fetch(FetchDescriptor<ServiceRecordEntity>()).validRecords()
        let rules = try context.fetch(FetchDescriptor<MaintenanceRuleEntity>()).validRules()
        return MaintenanceSnapshot(vehicles: vehicles, records: records, rules: rules)
    }
}
