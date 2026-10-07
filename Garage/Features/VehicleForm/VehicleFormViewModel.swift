import Foundation
import GarageCore
import Observation

/// Состояние формы машины: «Новая машина» или правка существующей. Проверку и сохранение делают
/// `AddVehicle` / `UpdateVehicle`.
@Observable
final class VehicleFormViewModel {
    typealias Field = VehicleDraft.Field

    enum Mode {
        case add
        case edit(original: Vehicle)
    }

    var draft: VehicleDraft
    private(set) var errors: [Field: VehicleDraft.FieldError] = [:]
    private(set) var isSaving = false
    /// Привязаны к алертам вью, поэтому изменяемы снаружи.
    var saveFailed = false
    /// Машину удалили, пока форма была открыта (например, на другом устройстве): вью показывает алерт и
    /// закрывает форму.
    var vehicleGone = false

    let mode: Mode
    /// Пробег машины по записям об обслуживании (для подсказки); `nil` — подсказка не нужна.
    let recordsMileageKm: Int?
    private let addVehicle: AddVehicle
    private let updateVehicle: UpdateVehicle
    private let currentYear: () -> Int

    /// - Parameters:
    ///   - recordsMileageKm: пробег по записям; передаёт вызывающий, в режиме добавления не нужен.
    ///   - currentYear: текущий год; замыкание, чтобы ViewModel не знала о календаре и часах.
    init(
        mode: Mode, recordsMileageKm: Int? = nil,
        addVehicle: AddVehicle, updateVehicle: UpdateVehicle, currentYear: @escaping () -> Int
    ) {
        self.mode = mode
        self.recordsMileageKm = recordsMileageKm
        self.addVehicle = addVehicle
        self.updateVehicle = updateVehicle
        self.currentYear = currentYear
        switch mode {
        case .add:
            draft = VehicleDraft()
        case .edit(let original):
            draft = VehicleDraft(vehicle: original)
            // Машина из синхронизации может не пройти проверку черновика, а `UpdateVehicle` не сохранит её,
            // пока поля не исправлены: ошибки видны сразу.
            do {
                _ = try draft.makeVehicle(id: original.id, currentYear: currentYear())
            } catch {
                errors = error.fields
            }
        }
    }

    var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    /// Пробег по записям, если он больше введённого в форме (решение 5 плана: ручное значение остаётся,
    /// итоговый пробег — вычисляемый).
    var recordsMileageHintKm: Int? {
        guard let recordsMileageKm, case .success(let manual) = ServiceRecordDraft.parseMileage(draft.mileageText),
            recordsMileageKm > manual
        else { return nil }
        return recordsMileageKm
    }

    func clearError(for field: Field) {
        errors[field] = nil
    }

    /// - Returns: `true`, если машина сохранена и форму можно закрывать.
    func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        // Ошибки прошлой попытки заменяются результатом этой проверки.
        errors = [:]
        do {
            switch mode {
            case .add:
                try await addVehicle.execute(draft: draft, currentYear: currentYear())
            case .edit(let original):
                try await updateVehicle.execute(draft: draft, original: original, currentYear: currentYear())
            }
            return true
        } catch let failure as VehicleDraft.Errors {
            errors = failure.fields
        } catch RepositoryError.vehicleNotFound {
            vehicleGone = true
        } catch {
            saveFailed = true
        }
        return false
    }
}
