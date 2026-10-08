import Foundation

/// Добавление правила обслуживания: валидация черновика и сохранение.
public struct AddMaintenanceRule: Sendable {
    private let rules: any MaintenanceRuleRepository

    public init(rules: any MaintenanceRuleRepository) {
        self.rules = rules
    }

    /// - Throws: `MaintenanceRuleDraft.Errors` (как есть), если черновик не прошёл проверку;
    ///   ошибки репозитория (`RepositoryError.vehicleNotFound` и др.).
    public func execute(draft: MaintenanceRuleDraft, vehicleID: Vehicle.ID) async throws {
        let rule = try draft.makeRule(vehicleID: vehicleID)
        try await rules.add(rule)
    }
}

/// Правка правила обслуживания: валидация черновика и сохранение.
public struct UpdateMaintenanceRule: Sendable {
    private let rules: any MaintenanceRuleRepository

    public init(rules: any MaintenanceRuleRepository) {
        self.rules = rules
    }

    /// Проверяет черновик, сохраняет `id` и `vehicleID` исходного правила. Правило не изменилось →
    /// репозиторий не вызывается (синхронизация не получает лишний upsert). Исходное правило сравнивается
    /// в нормализованном виде (как после `makeRule`: обрезанный текст `.other`).
    /// - Throws: `MaintenanceRuleDraft.Errors` (как есть); ошибки репозитория (`RepositoryError.ruleNotFound`).
    public func execute(draft: MaintenanceRuleDraft, original: MaintenanceRule) async throws {
        let rule = try draft.makeRule(id: original.id, vehicleID: original.vehicleID)
        let baseline =
            (try? MaintenanceRuleDraft(rule: original).makeRule(id: original.id, vehicleID: original.vehicleID))
            ?? original
        if rule == baseline { return }
        try await rules.update(rule)
    }
}

/// Пересчёт системных уведомлений: снимок данных → сроки → окно → порт.
public struct RescheduleReminders: Sendable {
    private let snapshot: any MaintenanceSnapshotReading
    private let scheduler: any ReminderScheduling

    public init(snapshot: any MaintenanceSnapshotReading, scheduler: any ReminderScheduling) {
        self.snapshot = snapshot
        self.scheduler = scheduler
    }

    /// Разрешение не спрашивает (это делает форма правила). Без разрешения (`notDetermined`, `denied`)
    /// снимок не читается и порт уведомлений не вызывается: `add` без разрешения бросает ошибку
    /// (проба 0.2), поставить набор «заранее» нельзя. Это не ошибка.
    /// - Throws: ошибки чтения снимка и `replaceAll`.
    public func execute(now: Date, calendar: Calendar) async throws {
        guard await scheduler.authorization() == .authorized else { return }
        let data = try await snapshot.snapshot()
        let reminders = MaintenanceSchedule.nextReminders(
            rules: data.rules, vehicles: data.vehicles, records: data.records, now: now, calendar: calendar)
        try await scheduler.replaceAll(with: reminders)
    }
}
