import GarageCore
import SwiftUI

extension MaintenanceStatus {
    /// Значение для `accessibilityValue` и UI-тестов: не зависит от языка.
    var accessibilityKey: String {
        switch self {
        case .ok: "ok"
        case .dueSoon: "dueSoon"
        case .overdue: "overdue"
        }
    }

    var systemImage: String {
        switch self {
        case .ok: "checkmark.circle"
        case .dueSoon: "clock.badge.exclamationmark"
        case .overdue: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .dueSoon: .orange
        case .overdue: .red
        }
    }
}

/// Тексты правила: срок, интервал и «от чего считаем». Пользовательские данные (`.other`) идут как есть.
struct MaintenanceRuleText {
    let status: MaintenanceRuleStatus
    let today: Date
    /// Григорианский календарь с поясом пользователя: так срок считает `MaintenanceSchedule`.
    let calendar: Calendar
    /// Календарь пользователя: даты показываются в нём, как и в строках истории рядом.
    private let displayCalendar: Calendar

    init(status: MaintenanceRuleStatus, today: Date, calendar: Calendar) {
        self.status = status
        self.today = today
        self.calendar = MaintenanceSchedule.gregorian(matching: calendar)
        self.displayCalendar = calendar
    }

    private var due: MaintenanceDue { status.due }

    /// «Сегодня» вместо «Скоро» в день срока.
    var statusTitle: LocalizedStringResource {
        if due.status == .dueSoon, let dueDay = due.dueDay, dueDay == CalendarDay(today, calendar: calendar) {
            return "Due today"
        }
        switch due.status {
        case .ok: return "On track"
        case .dueSoon: return "Due soon"
        case .overdue: return "Overdue"
        }
    }

    /// «Интервал: 12 месяцев или 10 000 км».
    var interval: String {
        let period = status.rule.period.map(Self.title(of:))
        let distance = status.rule.distanceKm?.kilometers
        switch (period, distance) {
        case (let period?, let distance?): return String(localized: "Interval: \(period) or \(distance)")
        case (let period?, nil): return String(localized: "Interval: \(period)")
        case (nil, let distance?): return String(localized: "Interval: \(distance)")
        case (nil, nil): return ""
        }
    }

    /// «Срок: 08.10.2027 или 97 400 км».
    var dueLine: String {
        let date = due.dueDay.flatMap { $0.date(in: calendar) }.map(formatted)
        let distance = due.dueMileageKm?.kilometers
        switch (date, distance) {
        case (let date?, let distance?): return String(localized: "Due by \(date) or at \(distance)")
        case (let date?, nil): return String(localized: "Due by \(date)")
        case (nil, let distance?): return String(localized: "Due at \(distance)")
        case (nil, nil): return ""
        }
    }

    /// «Последняя запись: 12.03.2026, 87 000 км» или «Отсчёт от 08.10.2026».
    var basisLine: String {
        switch due.basis {
        case .record(_, let date, let mileageKm):
            String(localized: "Last record: \(formatted(date)), \(mileageKm.kilometers)")
        case .start(let date, _):
            String(localized: "Counting from \(formatted(date))")
        }
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .abbreviated, time: .omitted, calendar: displayCalendar, timeZone: displayCalendar.timeZone))
    }

    private static func title(of period: ServicePeriod) -> String {
        switch period {
        case .days(let value): String(localized: "\(value) days")
        case .months(let value): String(localized: "\(value) months")
        }
    }
}

/// Значок статуса: идентификатор и `accessibilityValue` берут UI-тесты.
struct MaintenanceStatusLabel: View {
    let text: MaintenanceRuleText
    let identifier: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: text.status.due.status.systemImage)
                .foregroundStyle(text.status.due.status.color)
            // Зелёный текст на белом малоконтрастен: «в норме» — вторичным цветом, цветом выделяем только проблемы.
            Text(text.statusTitle)
                .foregroundStyle(
                    text.status.due.status == .ok
                        ? AnyShapeStyle(.secondary) : AnyShapeStyle(text.status.due.status.color))
        }
        .font(.subheadline)
        // Один элемент: иначе идентификатор достаётся и значку, и тексту, и тесты находят два совпадения.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text.statusTitle))
        .accessibilityValue(text.status.due.status.accessibilityKey)
        .accessibilityIdentifier(identifier)
    }
}

/// Строка правила: тип работ, статус, интервал, срок и основание расчёта.
struct MaintenanceRuleRow: View {
    let status: MaintenanceRuleStatus
    let today: Date
    let calendar: Calendar

    var body: some View {
        let text = MaintenanceRuleText(status: status, today: today, calendar: calendar)
        VStack(alignment: .leading, spacing: 2) {
            Text(status.rule.serviceType.title)
                .font(.headline)
            MaintenanceStatusLabel(text: text, identifier: AccessibilityID.MaintenanceRules.status(status.id))
            Text(verbatim: text.interval)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: text.dueLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: text.basisLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
