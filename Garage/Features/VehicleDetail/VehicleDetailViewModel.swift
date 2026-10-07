import Foundation
import GarageCore
import Observation

/// Состояние экрана машины: удаление записи из списка и удаление самой машины (подтверждение и сбой).
@Observable
final class VehicleDetailViewModel {
    /// Запись, для которой показан диалог подтверждения; `nil` — диалога нет (в том числе после отмены).
    var pendingDeletion: ServiceRecord.ID?
    /// Показан диалог подтверждения удаления машины.
    var isConfirmingVehicleDeletion = false
    /// Привязаны к алертам вью, поэтому изменяемы снаружи.
    var deleteFailed = false
    var vehicleDeleteFailed = false
    /// Идёт удаление записи или машины: общий флаг, пока идёт одно удаление, второе игнорируется.
    private(set) var isDeleting = false

    private let records: any ServiceRecordEditing
    private let vehicles: any VehicleRepository

    init(records: any ServiceRecordEditing, vehicles: any VehicleRepository) {
        self.records = records
        self.vehicles = vehicles
    }

    /// Удаляет подтверждённую запись. `id` передаёт вью из диалога: к моменту старта задачи
    /// `pendingDeletion` уже может быть сброшен закрытием диалога.
    func delete(id: ServiceRecord.ID) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        pendingDeletion = nil
        do {
            try await records.delete(id: id)
        } catch {
            deleteFailed = true
        }
    }

    /// Удаляет подтверждённую машину вместе с записями (каскад делают хранилище и сервер).
    /// - Returns: `true`, если машина удалена и экран можно закрывать.
    func deleteVehicle(id: Vehicle.ID) async -> Bool {
        guard !isDeleting else { return false }
        isDeleting = true
        defer { isDeleting = false }
        isConfirmingVehicleDeletion = false
        do {
            try await vehicles.delete(id: id)
            return true
        } catch {
            vehicleDeleteFailed = true
            return false
        }
    }
}
