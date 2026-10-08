import Foundation
import GarageCore
import Observation

/// Состояние формы правила: «Новое напоминание» или правка существующего. Валидацию и сохранение делают
/// `AddMaintenanceRule` / `UpdateMaintenanceRule`, удаление — порт `MaintenanceRuleRepository` напрямую.
@Observable
final class MaintenanceRuleFormViewModel {
    typealias Field = MaintenanceRuleDraft.Field

    enum Mode {
        /// `currentMileageKm` — пробег машины: по умолчанию «последнее ТО было» сегодня и на этом пробеге.
        case add(vehicleID: Vehicle.ID, currentMileageKm: Int)
        /// `unrecognizedPeriod` — сырой период, которого клиент не понял; пока поля интервала не тронуты, он сохраняется.
        case edit(original: MaintenanceRule, unrecognizedPeriod: String?)
    }

    /// Интервал по времени по умолчанию в новом правиле.
    static let defaultPeriodMonths = 12

    var draft: MaintenanceRuleDraft
    private(set) var errors: [Field: MaintenanceRuleDraft.FieldError] = [:]
    private(set) var isSaving = false
    private(set) var isDeleting = false
    /// Привязаны к алертам вью, поэтому изменяемы снаружи.
    var saveFailed = false
    var deleteFailed = false
    /// Правило исчезло (например, удалено на другом устройстве): вью показывает алерт и закрывает форму.
    var ruleGone = false
    /// Машину удалили, пока форма была открыта: вью показывает алерт и закрывает форму.
    var vehicleGone = false

    let mode: Mode
    private let addRule: AddMaintenanceRule
    private let updateRule: UpdateMaintenanceRule
    private let rules: any MaintenanceRuleRepository
    private let scheduler: any ReminderScheduling
    private let permissionChanged: () -> Void

    /// - Parameters:
    ///   - today: «сегодня» для стартовой даты нового правила.
    ///   - permissionChanged: после запроса разрешения: уведомления можно ставить, нужен пересчёт.
    init(
        mode: Mode, today: Date, addRule: AddMaintenanceRule, updateRule: UpdateMaintenanceRule,
        rules: any MaintenanceRuleRepository, scheduler: any ReminderScheduling,
        permissionChanged: @escaping () -> Void = {}
    ) {
        self.mode = mode
        self.addRule = addRule
        self.updateRule = updateRule
        self.rules = rules
        self.scheduler = scheduler
        self.permissionChanged = permissionChanged
        switch mode {
        case .add(_, let currentMileageKm):
            draft = MaintenanceRuleDraft(
                periodValueText: String(Self.defaultPeriodMonths), startDate: today,
                startMileageText: String(currentMileageKm))
        case .edit(let original, let unrecognizedPeriod):
            draft = MaintenanceRuleDraft(rule: original, unrecognizedPeriod: unrecognizedPeriod)
        }
    }

    var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    /// Идёт сохранение или удаление: кнопки действий блокируют друг друга.
    var isBusy: Bool { isSaving || isDeleting }

    func clearError(for field: Field) {
        errors[field] = nil
        // Ошибка «нет интервала» снимается выбором любого интервала.
        if field == .period || field == .distance { errors[.interval] = nil }
    }

    /// - Returns: `true`, если правило сохранено и форму можно закрывать.
    func save() async -> Bool {
        guard !isBusy else { return false }
        isSaving = true
        defer { isSaving = false }
        // Ошибки прошлой попытки заменяются результатом этой проверки.
        errors = [:]
        do {
            switch mode {
            case .add(let vehicleID, _):
                try await addRule.execute(draft: draft, vehicleID: vehicleID)
            case .edit(let original, _):
                try await updateRule.execute(draft: draft, original: original)
            }
        } catch let failure as MaintenanceRuleDraft.Errors {
            errors = failure.fields
            return false
        } catch RepositoryError.ruleNotFound {
            ruleGone = true
            return false
        } catch RepositoryError.vehicleNotFound {
            vehicleGone = true
            return false
        } catch {
            saveFailed = true
            return false
        }
        await requestAuthorizationIfNeeded()
        return true
    }

    /// Удаляет редактируемое правило. Только в режиме правки; повторный вызов во время работы игнорируется.
    /// - Returns: `true`, если правило удалено и форму можно закрывать.
    func delete() async -> Bool {
        guard case .edit(let original, _) = mode, !isBusy else { return false }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await rules.delete(id: original.id)
            return true
        } catch {
            deleteFailed = true
            return false
        }
    }

    /// Разрешение спрашиваем в момент, когда пользователь впервые завёл правило, по которому придёт уведомление
    /// (решение 11): при запуске запрос был бы без контекста. Правило только по пробегу уведомлений не создаёт,
    /// ради него не спрашиваем. Отказ не отменяет сохранение — правило работает в приложении.
    private func requestAuthorizationIfNeeded() async {
        guard draft.usesPeriod, await scheduler.authorization() == .notDetermined else { return }
        _ = await scheduler.requestAuthorization()
        permissionChanged()
    }
}
