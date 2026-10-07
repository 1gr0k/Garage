import Foundation
import GarageCore
import Observation

/// Состояние списка машин: удаление свайпом (подтверждение и сбой).
@Observable
final class VehicleListViewModel {
    /// Машина, для которой показан диалог подтверждения; `nil` — диалога нет (в том числе после отмены).
    var pendingDeletion: Vehicle.ID?
    /// Привязан к алерту вью, поэтому изменяем снаружи.
    var deleteFailed = false
    private(set) var isDeleting = false

    private let vehicles: any VehicleRepository

    init(vehicles: any VehicleRepository) {
        self.vehicles = vehicles
    }

    /// Удаляет подтверждённую машину. `id` передаёт вью из диалога: к моменту старта задачи
    /// `pendingDeletion` уже может быть сброшен закрытием диалога.
    func delete(id: Vehicle.ID) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        pendingDeletion = nil
        do {
            try await vehicles.delete(id: id)
        } catch {
            deleteFailed = true
        }
    }
}
