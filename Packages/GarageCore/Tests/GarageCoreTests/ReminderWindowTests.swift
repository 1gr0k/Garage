import Foundation
import Testing

@testable import GarageCore

private let calendar = makeCalendar()

private func reminders(
    rules: [MaintenanceRule], vehicles: [Vehicle]? = nil, records: [ServiceRecord] = [], now: Date,
    limit: Int = ReminderWindow.limit
) throws -> [ScheduledReminder] {
    MaintenanceSchedule.nextReminders(
        rules: rules, vehicles: try vehicles ?? [makeVehicle()], records: records, now: now, calendar: calendar,
        limit: limit)
}

@Test func futureDueDayGivesOneReminderAtTenInTheMorning() throws {
    let rule = try makeRule(period: .days(30), startDate: noon(2026, 1, 1))
    let result = try reminders(rules: [rule], now: noon(2026, 1, 2))

    #expect(result.count == 1)
    let reminder = try #require(result.first)
    #expect(reminder.ruleID == rule.id)
    #expect(reminder.vehicleID == testVehicleID)
    #expect(reminder.vehicleName == "Toyota Land Cruiser")
    #expect(reminder.serviceType == .oilChange)
    #expect(reminder.fireAt == DateComponents(year: 2026, month: 1, day: 31, hour: 10, minute: 0))
    #expect(reminder.fireAt.timeZone == nil)
}

@Test func pastDueDayGivesNoReminder() throws {
    let rule = try makeRule(period: .days(30), startDate: noon(2026, 1, 1))
    #expect(try reminders(rules: [rule], now: noon(2026, 2, 1)).isEmpty)
}

@Test func dueTodayCountsOnlyBeforeTenOClock() throws {
    let rule = try makeRule(period: .days(30), startDate: noon(2026, 1, 1))
    let nineAM = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 9))!
    let tenAM = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 10))!
    let afternoon = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 15))!

    #expect(try reminders(rules: [rule], now: nineAM).count == 1)
    #expect(try reminders(rules: [rule], now: tenAM).isEmpty)
    #expect(try reminders(rules: [rule], now: afternoon).isEmpty)
}

@Test func mileageOnlyRuleNeverNotifies() throws {
    let rule = try makeRule(period: nil, distanceKm: 10_000)
    #expect(try reminders(rules: [rule], now: noon(2026, 1, 2)).isEmpty)
}

@Test func mileageDoesNotCancelTheDateReminder() throws {
    // Пробег уже превышен, но дата в будущем: уведомление по дате остаётся.
    let rule = try makeRule(period: .months(12), distanceKm: 10_000, startMileageKm: 87_000)
    let vehicle = try makeVehicle(mileageKm: 120_000)
    #expect(try reminders(rules: [rule], vehicles: [vehicle], now: noon(2026, 1, 11)).count == 1)
}

@Test func ordersByDateThenByRuleID() throws {
    let low = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let high = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    let later = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!
    let rules = [
        try makeRule(id: high, period: .days(10), startDate: noon(2026, 1, 1)),
        try makeRule(id: later, period: .days(20), startDate: noon(2026, 1, 1)),
        try makeRule(id: low, period: .days(10), startDate: noon(2026, 1, 1)),
    ]
    #expect(try reminders(rules: rules, now: noon(2026, 1, 2)).map(\.ruleID) == [low, high, later])
}

@Test func keepsTheNearestSixtyOfSixtyOne() throws {
    let rules = try (1...61).map { try makeRule(period: .days($0), startDate: noon(2026, 1, 1)) }
    // Порядок на входе не важен.
    let result = try reminders(rules: rules.reversed(), now: noon(2026, 1, 1))

    #expect(result.count == 60)
    #expect(result.count == ReminderWindow.limit)
    #expect(Set(result.map(\.ruleID)) == Set(rules.prefix(60).map(\.id)))
    #expect(result.map(\.ruleID) == rules.prefix(60).map(\.id))
}

@Test func customLimitIsHonored() throws {
    let rules = try (1...5).map { try makeRule(period: .days($0), startDate: noon(2026, 1, 1)) }
    #expect(try reminders(rules: rules, now: noon(2026, 1, 1), limit: 3).map(\.ruleID) == rules.prefix(3).map(\.id))
    #expect(try reminders(rules: rules, now: noon(2026, 1, 1), limit: 0).isEmpty)
}

@Test func ruleOfAMissingVehicleGivesNoReminder() throws {
    let rule = try makeRule(vehicleID: otherVehicleID, period: .days(30), startDate: noon(2026, 1, 1))
    #expect(try reminders(rules: [rule], now: noon(2026, 1, 2)).isEmpty)
}

@Test func lastRecordMovesTheReminder() throws {
    let rule = try makeRule(period: .months(12), startDate: noon(2026, 1, 1))
    let record = try makeRecord(date: noon(2026, 5, 20))
    let result = try reminders(rules: [rule], records: [record], now: noon(2026, 6, 1))

    #expect(result.first?.fireAt == DateComponents(year: 2027, month: 5, day: 20, hour: 10, minute: 0))
}

@Test func repeatedCallOnTheSameDataGivesTheSameResult() throws {
    let rules = try (1...10).map { try makeRule(period: .days($0 * 3), startDate: noon(2026, 1, 1)) }
    let first = try reminders(rules: rules, now: noon(2026, 1, 2))
    let second = try reminders(rules: rules, now: noon(2026, 1, 2))
    #expect(first == second)
    #expect(first.count == 10)
}
