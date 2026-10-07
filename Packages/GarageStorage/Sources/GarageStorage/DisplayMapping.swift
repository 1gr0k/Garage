import Foundation
import GarageCore
import OSLog

private let logger = Logger(subsystem: "Garage", category: "Storage")

/// Строка списка машин.
public struct VehicleListItem: Identifiable, Hashable, Sendable {
    public var vehicle: Vehicle
    public var recordCount: Int

    public var id: Vehicle.ID { vehicle.id }

    public init(vehicle: Vehicle, recordCount: Int) {
        self.vehicle = vehicle
        self.recordCount = recordCount
    }
}

extension VehicleEntity {
    public func listItem() throws -> VehicleListItem {
        VehicleListItem(vehicle: try toDomain(), recordCount: serviceRecords.count)
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
