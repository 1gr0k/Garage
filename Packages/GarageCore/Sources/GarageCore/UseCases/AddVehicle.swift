import Foundation

/// Добавление машины: валидация черновика и сохранение.
public struct AddVehicle: Sendable {
    private let vehicles: any VehicleRepository

    public init(vehicles: any VehicleRepository) {
        self.vehicles = vehicles
    }

    /// - Throws: `VehicleDraft.Errors` (как есть), если черновик не прошёл проверку; ошибки репозитория.
    public func execute(draft: VehicleDraft, currentYear: Int) async throws {
        let vehicle = try draft.makeVehicle(currentYear: currentYear)
        try await vehicles.add(vehicle)
    }
}
