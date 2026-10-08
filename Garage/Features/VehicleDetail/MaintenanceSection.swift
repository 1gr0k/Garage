import GarageCore
import SwiftUI

/// Секция «Обслуживание» на экране машины: ближайшее по статусу правило одной строкой и переход ко всем.
struct MaintenanceSection: View {
    let vehicleID: Vehicle.ID
    /// Правила машины в порядке важности (`MaintenanceOverview.statuses`): первое — ближайшее.
    let statuses: [MaintenanceRuleStatus]
    let today: Date
    let calendar: Calendar

    var body: some View {
        Section("Maintenance") {
            if let top = statuses.first {
                let text = MaintenanceRuleText(status: top, today: today, calendar: calendar)
                VStack(alignment: .leading, spacing: 2) {
                    Text(top.rule.serviceType.title)
                        .font(.headline)
                    MaintenanceStatusLabel(text: text, identifier: AccessibilityID.VehicleDetail.maintenanceSummary)
                    Text(verbatim: text.dueLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                MaintenanceRulesView(vehicleID: vehicleID)
            } label: {
                LabeledContent("Reminders", value: statuses.count.formatted())
            }
            .accessibilityIdentifier(AccessibilityID.VehicleDetail.maintenanceAll)
        }
    }
}
