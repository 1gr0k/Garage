import Foundation
import GarageCore
import OSLog

private let logger = Logger(subsystem: "Garage", category: "Storage")

/// Строка списка машин.
public struct VehicleListItem: Identifiable, Hashable, Sendable {
    public var vehicle: Vehicle
    public var recordCount: Int
    /// Исходный вид машины, если сервер прислал незнакомый (в `vehicle.kind` тогда `.car`): форма правки
    /// открывается с ним и не выбирает вид за пользователя (решение 9e плана этапа 12).
    public var rawKind: String?

    public var id: Vehicle.ID { vehicle.id }

    public init(vehicle: Vehicle, recordCount: Int, rawKind: String? = nil) {
        self.vehicle = vehicle
        self.recordCount = recordCount
        self.rawKind = rawKind
    }
}

extension VehicleEntity {
    public func listItem() throws -> VehicleListItem {
        VehicleListItem(vehicle: try toDomain(), recordCount: serviceRecords.count, rawKind: rawKind)
    }
}

/// Всё, что нужно форме правки правила: само правило и сырой период, которого клиент не понял.
public struct MaintenanceRuleEditingSnapshot: Identifiable, Hashable, Sendable {
    public var rule: MaintenanceRule
    public var rawPeriod: String?

    public var id: MaintenanceRule.ID { rule.id }

    public init(rule: MaintenanceRule, rawPeriod: String?) {
        self.rule = rule
        self.rawPeriod = rawPeriod
    }
}

extension MaintenanceRuleEntity {
    public func editingSnapshot() throws -> MaintenanceRuleEditingSnapshot {
        MaintenanceRuleEditingSnapshot(rule: try toDomain(), rawPeriod: rawPeriod)
    }
}

extension Sequence where Element == MaintenanceRuleEntity {
    public func validRules() -> [MaintenanceRule] {
        compactMap { entity in
            do {
                return try entity.toDomain()
            } catch {
                logger.error("Skipping invalid maintenance rule \(entity.id, privacy: .public): \(error)")
                return nil
            }
        }
    }
}

/// Единственное место, где сущности для показа превращаются в домен: битые пропускаются с записью в лог.
extension Sequence where Element == VehicleEntity {
    public func validVehicles() -> [VehicleListItem] {
        compactMap { entity in
            do {
                return try entity.listItem()
            } catch {
                logger.error("Skipping invalid vehicle \(entity.id, privacy: .public): \(error)")
                return nil
            }
        }
    }
}

/// Всё, что нужно форме правки записи.
public struct ServiceRecordEditingSnapshot: Identifiable, Hashable, Sendable {
    public var record: ServiceRecord
    public var hasReceipt: Bool
    /// `nil`, если чека нет или его байты ещё не скачаны (`hasReceipt == true`).
    public var receiptImage: Data?

    public var id: ServiceRecord.ID { record.id }

    public init(record: ServiceRecord, hasReceipt: Bool, receiptImage: Data?) {
        self.record = record
        self.hasReceipt = hasReceipt
        self.receiptImage = receiptImage
    }
}

extension ServiceRecordEntity {
    public func editingSnapshot() throws -> ServiceRecordEditingSnapshot {
        ServiceRecordEditingSnapshot(record: try toDomain(), hasReceipt: hasReceipt, receiptImage: receiptImage)
    }
}

extension Sequence where Element == ServiceRecordEntity {
    public func validRecords() -> [ServiceRecord] {
        compactMap { entity in
            do {
                return try entity.toDomain()
            } catch {
                logger.error("Skipping invalid record \(entity.id, privacy: .public): \(error)")
                return nil
            }
        }
    }
}
