import Foundation

/// Что сделать с интервалом по времени правила при правке — по образцу `VehicleKindChange` (решение 9e плана
/// этапа 12, открытый вопрос S).
///
/// Сервер мог прислать период, которого этот клиент не знает (`"weeks:2"`): в домене `period == nil`, а исходная
/// строка хранится рядом и уходит обратно. «Пользователь убрал интервал по времени» неотличимо от «не трогал» по
/// самому правилу, поэтому намерение явное.
public enum MaintenancePeriodChange: Hashable, Sendable {
    /// Поле интервала по времени не трогали: сырая строка хранилища остаётся и уходит на сервер без изменений.
    case keepUnrecognized
    /// Поле тронули явно (`rule.period`, в том числе `nil`): сырая строка сбрасывается.
    case set
}

/// Хранилище правил обслуживания. Очередь синхронизации и каскад с машиной — забота адаптера.
public protocol MaintenanceRuleRepository: Sendable {
    /// - Throws: `RepositoryError.vehicleNotFound`, если машины правила нет.
    func add(_ rule: MaintenanceRule) async throws
    /// Заменяет поля правила с тем же `id`; `vehicleID` не меняется.
    /// - Throws: `RepositoryError.ruleNotFound`, если правила нет.
    func update(_ rule: MaintenanceRule, period: MaintenancePeriodChange) async throws
    /// Удаляет правило. Правила нет — не ошибка.
    func delete(id: MaintenanceRule.ID) async throws
}

/// Снимок данных для пересчёта напоминаний.
public struct MaintenanceSnapshot: Hashable, Sendable {
    public var vehicles: [Vehicle]
    public var records: [ServiceRecord]
    public var rules: [MaintenanceRule]

    public init(vehicles: [Vehicle] = [], records: [ServiceRecord] = [], rules: [MaintenanceRule] = []) {
        self.vehicles = vehicles
        self.records = records
        self.rules = rules
    }
}

public protocol MaintenanceSnapshotReading: Sendable {
    /// Все машины, записи и правила; нечитаемые сущности адаптер пропускает.
    func snapshot() async throws -> MaintenanceSnapshot
}

/// Что показывает уведомление. В GarageCore пользовательских строк нет, поэтому порт получает смысл,
/// а текст собирает адаптер приложения из каталога.
public struct ScheduledReminder: Hashable, Sendable {
    public var ruleID: MaintenanceRule.ID
    public var vehicleID: Vehicle.ID
    /// Пользовательские данные: в текст — как есть.
    public var vehicleName: String
    public var serviceType: ServiceType
    /// Год, месяц, день, час, минута — без `timeZone`: срабатывает в это время того пояса, где устройство.
    public var fireAt: DateComponents

    public init(
        ruleID: MaintenanceRule.ID, vehicleID: Vehicle.ID, vehicleName: String, serviceType: ServiceType,
        fireAt: DateComponents
    ) {
        self.ruleID = ruleID
        self.vehicleID = vehicleID
        self.vehicleName = vehicleName
        self.serviceType = serviceType
        self.fireAt = fireAt
    }
}

public enum ReminderAuthorization: Hashable, Sendable {
    case notDetermined
    case authorized
    case denied
}

public protocol ReminderScheduling: Sendable {
    func authorization() async -> ReminderAuthorization
    /// Показывает системный запрос, если статус `notDetermined`. Возвращает итоговый статус.
    func requestAuthorization() async -> ReminderAuthorization
    /// Приводит набор отложенных уведомлений приложения ровно к `reminders` (по стабильным id).
    func replaceAll(with reminders: [ScheduledReminder]) async throws
}
