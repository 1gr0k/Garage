import Foundation
import GarageCore
import OSLog
@preconcurrency import UserNotifications

private nonisolated let logger = Logger(subsystem: "Garage", category: "Reminders")

/// `ReminderScheduling` поверх `UNUserNotificationCenter`. Платформенный адаптер с текстами из каталога приложения.
///
/// Тонкий перевод `ScheduledReminder` в запрос: окно, порядок, отбор прошедших сроков и проверка разрешения —
/// в GarageCore (`MaintenanceSchedule.nextReminders`, `RescheduleReminders`). Автотестов самого центра нет:
/// без разрешения `add` бросает 2003, а выдать его заранее нечем (проба 0.1–0.2); тестируется чистая `makeRequest`.
nonisolated struct UserNotificationsReminderScheduler: ReminderScheduling {
    /// Адаптер трогает только свои запросы.
    static let identifierPrefix = "maintenance-rule."

    static func identifier(for ruleID: MaintenanceRule.ID) -> String {
        identifierPrefix + ruleID.uuidString
    }

    func authorization() async -> ReminderAuthorization {
        Self.map(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> ReminderAuthorization {
        let center = UNUserNotificationCenter.current()
        if Self.map(await center.notificationSettings().authorizationStatus) == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                logger.error("requestAuthorization failed: \(error)")
            }
        }
        return await authorization()
    }

    /// Снимает свои запросы, которых нет в наборе, и ставит новые и изменившиеся; одинаковые по содержимому не трогает
    /// (повторный `add` с тем же id заменил бы запрос, проба 0.5, но сбивал бы системную очередь).
    func replaceAll(with reminders: [ScheduledReminder]) async throws {
        let center = UNUserNotificationCenter.current()
        // Тексты берёт `ServiceType.title` — он живёт на главном акторе, как и весь слой форматирования приложения.
        let requests = await MainActor.run { reminders.map(Self.makeRequest) }
        let wanted = Dictionary(requests.map { ($0.identifier, $0) }, uniquingKeysWith: { $1 })
        let pending = await center.pendingNotificationRequests().filter {
            $0.identifier.hasPrefix(Self.identifierPrefix)
        }
        let stale = pending.map(\.identifier).filter { wanted[$0] == nil }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
            #if DEBUG
                for identifier in stale { logger.info("Removed \(identifier, privacy: .public)") }
            #endif
        }
        let current = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { $1 })
        var added = 0
        for (identifier, request) in wanted.sorted(by: { $0.key < $1.key }) {
            if let existing = current[identifier], Self.isSame(existing, request) { continue }
            try await center.add(request)
            added += 1
            #if DEBUG
                // Ручная проверка адаптера: идентификатор и момент срабатывания видны в `log stream` (проба 0.4).
                let fireDate = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                logger.info(
                    "Scheduled \(identifier, privacy: .public) fires at \(fireDate?.description ?? "nil", privacy: .public)"
                )
            #endif
        }
        logger.info("Reminders: \(wanted.count) wanted, \(stale.count) removed, \(added) added")
    }

    /// Чистый перевод смысла в запрос. `fireAt` — компоненты **без** `timeZone` (срабатывает в 10:00 того пояса, где
    /// устройство, проба 0.4), но в григорианском календаре: иначе год прочтётся в календаре пользователя.
    @MainActor
    static func makeRequest(_ reminder: ScheduledReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time for \(reminder.serviceType.title)")
        // Имя машины — пользовательские данные, в каталог не попадает.
        content.body = reminder.vehicleName
        content.sound = .default
        content.threadIdentifier = reminder.vehicleID.uuidString
        content.userInfo = [
            "vehicleID": reminder.vehicleID.uuidString,
            "ruleID": reminder.ruleID.uuidString,
        ]
        var components = reminder.fireAt
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = nil
        return UNNotificationRequest(
            identifier: identifier(for: reminder.ruleID), content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    private static func isSame(_ lhs: UNNotificationRequest, _ rhs: UNNotificationRequest) -> Bool {
        guard let left = lhs.trigger as? UNCalendarNotificationTrigger,
            let right = rhs.trigger as? UNCalendarNotificationTrigger
        else { return false }
        return lhs.content.title == rhs.content.title && lhs.content.body == rhs.content.body
            && lhs.content.threadIdentifier == rhs.content.threadIdentifier
            && left.dateComponents.year == right.dateComponents.year
            && left.dateComponents.month == right.dateComponents.month
            && left.dateComponents.day == right.dateComponents.day
            && left.dateComponents.hour == right.dateComponents.hour
            && left.dateComponents.minute == right.dateComponents.minute
    }

    private static func map(_ status: UNAuthorizationStatus) -> ReminderAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        // Временное и «эфемерное» разрешение достаточно, чтобы ставить уведомления.
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .denied
        }
    }
}
