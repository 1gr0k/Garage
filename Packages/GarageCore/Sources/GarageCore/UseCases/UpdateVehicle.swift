import Foundation

/// Правка машины: валидация черновика и сохранение.
public struct UpdateVehicle: Sendable {
    private let vehicles: any VehicleRepository

    public init(vehicles: any VehicleRepository) {
        self.vehicles = vehicles
    }

    /// Проверяет черновик и сохраняет `id` исходной машины.
    /// Ничего не изменилось → репозиторий не вызывается (синхронизация не получает лишний upsert).
    /// Исходная машина сравнивается в нормализованном виде (как после `makeVehicle`: обрезанные пробелы),
    /// иначе машина с пробелами в марке считалась бы изменённой.
    /// Если исходная машина сама не проходит проверку черновика (год вне `1900...currentYear + 1`, пробег
    /// больше лимита — такое может прийти синхронизацией), сравнение идёт с ней как есть, а любое сохранение
    /// бросит ошибки полей, пока пользователь их не исправит. Форма показывает эти ошибки сразу при открытии.
    /// - Throws: `VehicleDraft.Errors` (как есть), если черновик не прошёл проверку;
    ///   ошибки репозитория (`RepositoryError.vehicleNotFound` и др.).
    public func execute(draft: VehicleDraft, original: Vehicle, currentYear: Int) async throws {
        let vehicle = try draft.makeVehicle(id: original.id, currentYear: currentYear)
        let baseline =
            (try? VehicleDraft(vehicle: original).makeVehicle(id: original.id, currentYear: currentYear))
            ?? original
        if vehicle == baseline { return }
        try await vehicles.update(vehicle)
    }
}
