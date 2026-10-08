import Foundation

/// Календарный день без времени и часового пояса. Год — григорианский (эпохи не хранятся): считать в
/// других календарях нельзя, `MaintenanceSchedule` сам переходит на григорианский.
public struct CalendarDay: Hashable, Sendable, Comparable, Codable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// День, на который `date` приходится в `calendar`.
    public init(_ date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year ?? 0, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// Начало этого дня в `calendar`.
    public func date(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Сколько календарных дней от `self` до `other` (отрицательное, если `other` раньше).
    public func days(until other: CalendarDay, calendar: Calendar) -> Int? {
        guard let from = date(in: calendar), let to = other.date(in: calendar) else { return nil }
        return calendar.dateComponents([.day], from: from, to: to).day
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// Насколько близок срок. Порядок важен: `ok < dueSoon < overdue`.
public enum MaintenanceStatus: Int, Hashable, Sendable, Comparable {
    case ok
    case dueSoon
    case overdue

    public static func < (lhs: MaintenanceStatus, rhs: MaintenanceStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// От чего посчитан срок: от последней записи этого типа или, если записей нет, от старта правила.
public enum MaintenanceBasis: Hashable, Sendable {
    case record(id: ServiceRecord.ID, date: Date, mileageKm: Int)
    case start(date: Date, mileageKm: Int)

    public var date: Date {
        switch self {
        case .record(_, let date, _), .start(let date, _): date
        }
    }

    public var mileageKm: Int {
        switch self {
        case .record(_, _, let mileageKm), .start(_, let mileageKm): mileageKm
        }
    }
}

public struct MaintenanceDue: Hashable, Sendable {
    public var basis: MaintenanceBasis
    /// День срока по времени; `nil`, если у правила нет интервала по времени.
    public var dueDay: CalendarDay?
    /// Пробег срока; `nil`, если у правила нет интервала по пробегу.
    public var dueMileageKm: Int?
    public var status: MaintenanceStatus
}

public enum MaintenanceSchedule {
    /// «Скоро» — не более чем за столько дней до срока (включая день срока)…
    public static let soonDays = 30
    /// …или километров. Для коротких интервалов порог — половина интервала (см. `due`).
    public static let soonKm = 1_000

    /// Срок правила — чистая функция без побочных эффектов.
    ///
    /// - Базис: последняя запись этого типа **у этой машины** (самая поздняя по дню, при равных днях —
    ///   с большим пробегом); от неё берутся и дата, и пробег. Записей нет — `rule.start`.
    ///   Если записи есть, `start` не используется, даже когда он новее: запись — факт, `start` — допущение.
    /// - Дата срока — календарный день: начало дня базиса плюс интервал (`date(byAdding:)`, поэтому
    ///   31 января + 1 месяц = конец февраля).
    /// - Статус — худший из двух измерений (общей шкалы у дней и километров нет): просрочено со следующего
    ///   дня после срока или когда `currentMileageKm >= dueMileageKm`; «скоро» — за `soonDays`/`soonKm`.
    public static func due(
        for rule: MaintenanceRule,
        records: some Sequence<ServiceRecord>,
        currentMileageKm: Int,
        today: Date,
        calendar: Calendar
    ) -> MaintenanceDue {
        let calendar = Self.gregorian(matching: calendar)
        let basis = Self.basis(for: rule, records: records, calendar: calendar)

        var status = MaintenanceStatus.ok
        var dueDay: CalendarDay?
        if let period = rule.period {
            let startOfBasis = calendar.startOfDay(for: basis.date)
            let component: Calendar.Component
            switch period {
            case .days: component = .day
            case .months: component = .month
            }
            if let dueDate = calendar.date(byAdding: component, value: period.value, to: startOfBasis) {
                let day = CalendarDay(dueDate, calendar: calendar)
                dueDay = day
                if let left = CalendarDay(today, calendar: calendar).days(until: day, calendar: calendar) {
                    let threshold = min(soonDays, approximateDays(of: period) / 2)
                    status = max(status, left < 0 ? .overdue : left <= threshold ? .dueSoon : .ok)
                }
            }
        }

        var dueMileageKm: Int?
        if let distanceKm = rule.distanceKm {
            let due = basis.mileageKm + distanceKm
            dueMileageKm = due
            let remaining = due - currentMileageKm
            let threshold = min(soonKm, distanceKm / 2)
            status = max(status, remaining <= 0 ? .overdue : remaining <= threshold ? .dueSoon : .ok)
        }

        return MaintenanceDue(basis: basis, dueDay: dueDay, dueMileageKm: dueMileageKm, status: status)
    }

    /// Порог «скоро» не больше половины интервала: правило «каждые 14 дней» или «каждые 500 км» не должно
    /// быть «скоро» сразу после обслуживания. `soonDays`/`soonKm` — верхняя граница порога.
    private static func approximateDays(of period: ServicePeriod) -> Int {
        switch period {
        case .days(let value): value
        case .months(let value): value * 30
        }
    }

    /// Расчёт всегда идёт в григорианском календаре с поясом переданного: в календаре с эпохами (японский)
    /// год `CalendarDay` без эпохи был бы неоднозначным, а `fireAt` для уведомления — в григорианских
    /// компонентах (адаптер задаёт им `calendar: .gregorian`).
    static func gregorian(matching calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    private static func basis(
        for rule: MaintenanceRule, records: some Sequence<ServiceRecord>, calendar: Calendar
    ) -> MaintenanceBasis {
        let key = rule.serviceType.matchKey
        let latest =
            records
            .filter { $0.vehicleID == rule.vehicleID && $0.serviceType.matchKey == key }
            .max { lhs, rhs in
                let lhsKey = (CalendarDay(lhs.date, calendar: calendar), lhs.mileageKm, lhs.id.uuidString)
                let rhsKey = (CalendarDay(rhs.date, calendar: calendar), rhs.mileageKm, rhs.id.uuidString)
                return lhsKey < rhsKey
            }
        if let latest {
            return .record(id: latest.id, date: latest.date, mileageKm: latest.mileageKm)
        }
        return .start(date: rule.start.date, mileageKm: rule.start.mileageKm)
    }
}

/// Окно уведомлений: лимит iOS — 64 отложенных на приложение, система при превышении молча оставляет
/// **последние добавленные**, а не ближайшие (проба 0.3), поэтому окно режет приложение.
public enum ReminderWindow {
    public static let limit = 60
    /// Время доставки в день срока, по локальному «настенному» времени (без часового пояса).
    public static let fireHour = 10
}

extension MaintenanceSchedule {
    /// Уведомления, которые надо поставить: по одному на правило с интервалом по времени, в день срока в
    /// `ReminderWindow.fireHour`, только в будущем; ближайшие `limit`, при равенстве — по `ruleID`.
    /// Правило только по пробегу уведомлений не создаёт (пробег виден в приложении). Правила без машины
    /// в `vehicles` пропускаются.
    public static func nextReminders(
        rules: [MaintenanceRule],
        vehicles: [Vehicle],
        records: [ServiceRecord],
        now: Date,
        calendar: Calendar,
        limit: Int = ReminderWindow.limit
    ) -> [ScheduledReminder] {
        let calendar = Self.gregorian(matching: calendar)
        let vehiclesByID = Dictionary(vehicles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var candidates: [(fireDate: Date, reminder: ScheduledReminder)] = []
        for rule in rules where rule.period != nil {
            guard let vehicle = vehiclesByID[rule.vehicleID] else { continue }
            let due = Self.due(
                for: rule, records: records, currentMileageKm: vehicle.currentMileageKm(records: records),
                today: now, calendar: calendar)
            guard let dueDay = due.dueDay else { continue }
            let fireAt = DateComponents(
                year: dueDay.year, month: dueDay.month, day: dueDay.day, hour: ReminderWindow.fireHour, minute: 0)
            guard let fireDate = calendar.date(from: fireAt), fireDate > now else { continue }
            candidates.append(
                (
                    fireDate,
                    ScheduledReminder(
                        ruleID: rule.id, vehicleID: vehicle.id, vehicleName: vehicle.displayName,
                        serviceType: rule.serviceType, fireAt: fireAt)
                ))
        }
        candidates.sort { ($0.fireDate, $0.reminder.ruleID.uuidString) < ($1.fireDate, $1.reminder.ruleID.uuidString) }
        return candidates.prefix(max(limit, 0)).map(\.reminder)
    }
}
