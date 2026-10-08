import Foundation
import GarageCore
import Testing
import UserNotifications

@testable import Garage

// Чистый перевод `ScheduledReminder` в запрос. Сам `UNUserNotificationCenter` не проверяется: без разрешения `add`
// бросает 2003, а выдать его заранее нечем (docs/plans/stage-12-reminders.md, пробы 0.1–0.2).
@MainActor
struct ReminderRequestTests {
    private let ruleID = UUID()
    private let vehicleID = UUID()

    private func reminder(serviceType: ServiceType = .oilChange, vehicleName: String = "Toyota Land Cruiser")
        -> ScheduledReminder
    {
        ScheduledReminder(
            ruleID: ruleID, vehicleID: vehicleID, vehicleName: vehicleName, serviceType: serviceType,
            fireAt: DateComponents(year: 2027, month: 3, day: 14, hour: 10, minute: 0))
    }

    @Test func requestHasStableIdentifierThreadAndUserInfo() throws {
        let request = UserNotificationsReminderScheduler.makeRequest(reminder())

        #expect(request.identifier == "maintenance-rule.\(ruleID.uuidString)")
        #expect(request.content.threadIdentifier == vehicleID.uuidString)
        #expect(request.content.userInfo["vehicleID"] as? String == vehicleID.uuidString)
        #expect(request.content.userInfo["ruleID"] as? String == ruleID.uuidString)
    }

    @Test func triggerIsOneShotGregorianWallClockTimeWithoutTimeZone() throws {
        let request = UserNotificationsReminderScheduler.makeRequest(reminder())
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)

        #expect(trigger.repeats == false)
        #expect(trigger.dateComponents.timeZone == nil)
        #expect(trigger.dateComponents.calendar?.identifier == .gregorian)
        #expect(trigger.dateComponents.year == 2027)
        #expect(trigger.dateComponents.month == 3)
        #expect(trigger.dateComponents.day == 14)
        #expect(trigger.dateComponents.hour == 10)
        #expect(trigger.dateComponents.minute == 0)
    }

    @Test func userDataIsVerbatimInTitleAndBody() {
        let request = UserNotificationsReminderScheduler.makeRequest(
            reminder(serviceType: .other("Антифриз %@"), vehicleName: "Нива %@ 4x4"))

        #expect(request.content.body == "Нива %@ 4x4")
        #expect(request.content.title == String(localized: "Time for \("Антифриз %@")"))
    }

    /// Заголовок собран шаблоном из каталога, а не равен названию типа: без обёртки тест краснеет.
    @Test func titleIsTheCatalogTemplateAroundTheServiceTypeName() {
        let request = UserNotificationsReminderScheduler.makeRequest(reminder(serviceType: .brakes))

        #expect(request.content.title == String(localized: "Time for \(ServiceType.brakes.title)"))
        #expect(request.content.title != ServiceType.brakes.title)
        #expect(!request.content.title.contains("%@"))
    }
}
