import Foundation
import GarageCore
import SwiftData

/// `VehicleRepository` поверх SwiftData. Каскад на записи и очередь синхронизации ведут
/// `VehicleLog.add` / `update` / `delete`.
public struct SwiftDataVehicleRepository: VehicleRepository {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func add(_ vehicle: Vehicle) async throws {
        try VehicleLog.add(vehicle, in: container)
    }

    public func update(_ vehicle: Vehicle, kind: VehicleKindChange) async throws {
        do {
            try VehicleLog.update(vehicle, kind: kind, in: container)
        } catch ServiceLogError.vehicleNotFound(let id) {
            throw RepositoryError.vehicleNotFound(id)
        }
    }

    public func delete(id: Vehicle.ID) async throws {
        try VehicleLog.delete(id: id, in: container)
    }
}
