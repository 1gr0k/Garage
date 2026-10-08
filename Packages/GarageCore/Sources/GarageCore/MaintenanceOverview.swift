import Foundation

/// Правило машины вместе с рассчитанным сроком — строка списка правил и секции на экране машины.
public struct MaintenanceRuleStatus: Identifiable, Hashable, Sendable {
    public var rule: MaintenanceRule
    public var due: MaintenanceDue

    public var id: MaintenanceRule.ID { rule.id }

    public init(rule: MaintenanceRule, due: MaintenanceDue) {
        self.rule = rule
        self.due = due
    }
}

public enum MaintenanceOverview {
    /// Правила одной машины со сроками. Порядок: хуже статус — выше; при равном статусе ближайший по дате срока
    /// (правила без интервала по времени — после правил с ним), затем по остатку пробега, затем по `id`
    /// (детерминизм). Текущий пробег считается из записей (`Vehicle.currentMileageKm(records:)`).
    public static func statuses(
        rules: [MaintenanceRule], vehicle: Vehicle, records: [ServiceRecord], today: Date, calendar: Calendar
    ) -> [MaintenanceRuleStatus] {
        let mileage = vehicle.currentMileageKm(records: records)
        return
            rules
            .filter { $0.vehicleID == vehicle.id }
            .map {
                MaintenanceRuleStatus(
                    rule: $0,
                    due: MaintenanceSchedule.due(
                        for: $0, records: records, currentMileageKm: mileage, today: today, calendar: calendar))
            }
            .sorted { lhs, rhs in
                if lhs.due.status != rhs.due.status { return lhs.due.status > rhs.due.status }
                switch (lhs.due.dueDay, rhs.due.dueDay) {
                case (let left?, let right?) where left != right: return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                let leftKm = lhs.due.dueMileageKm ?? Int.max
                let rightKm = rhs.due.dueMileageKm ?? Int.max
                if leftKm != rightKm { return leftKm < rightKm }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}
