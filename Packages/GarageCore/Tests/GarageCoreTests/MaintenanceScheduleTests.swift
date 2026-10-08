import Foundation
import Testing

@testable import GarageCore

private let calendar = makeCalendar()

private func due(
    _ rule: MaintenanceRule, records: [ServiceRecord] = [], mileage: Int = 87_000, today: Date,
    calendar: Calendar = calendar
) -> MaintenanceDue {
    MaintenanceSchedule.due(
        for: rule, records: records, currentMileageKm: mileage, today: today, calendar: calendar)
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
    CalendarDay(year: year, month: month, day: day)
}

// MARK: Базис

@Test func withoutRecordsTheRuleCountsFromItsStart() throws {
    let rule = try makeRule(period: .months(12), startDate: noon(2026, 1, 10), startMileageKm: 87_000)
    let result = due(rule, today: noon(2026, 2, 1))

    #expect(result.basis == .start(date: noon(2026, 1, 10), mileageKm: 87_000))
    #expect(result.dueDay == day(2027, 1, 10))
}

@Test func recordOlderThanStartStillWins() throws {
    let rule = try makeRule(period: .months(12), startDate: noon(2026, 1, 10))
    let record = try makeRecord(date: noon(2025, 6, 1), mileageKm: 80_000)
    let result = due(rule, records: [record], today: noon(2026, 2, 1))

    #expect(result.basis == .record(id: record.id, date: record.date, mileageKm: 80_000))
    #expect(result.dueDay == day(2026, 6, 1))
}

@Test func recordsOfOtherTypesAndOtherVehiclesAreIgnored() throws {
    let rule = try makeRule(period: .months(12), startDate: noon(2026, 1, 10))
    let records = [
        try makeRecord(serviceType: .brakes, date: noon(2026, 5, 1)),
        try makeRecord(vehicleID: otherVehicleID, date: noon(2026, 6, 1)),
    ]
    let result = due(rule, records: records, today: noon(2026, 7, 1))

    #expect(result.basis == .start(date: noon(2026, 1, 10), mileageKm: 87_000))
}

@Test func otherTypeMatchesByNormalizedKey() throws {
    let rule = try makeRule(serviceType: .other("  Антифриз "), period: .months(24))
    let record = try makeRecord(serviceType: .other("антифриз"), date: noon(2026, 3, 1))

    #expect(due(rule, records: [record], today: noon(2026, 4, 1)).dueDay == day(2028, 3, 1))
}

@Test func latestDateWinsAndTakesItsOwnMileage() throws {
    let rule = try makeRule(period: .months(12))
    let earlier = try makeRecord(date: noon(2026, 3, 1), mileageKm: 95_000)
    let later = try makeRecord(date: noon(2026, 5, 1), mileageKm: 90_000)
    let result = due(rule, records: [earlier, later], today: noon(2026, 6, 1))

    #expect(result.basis == .record(id: later.id, date: later.date, mileageKm: 90_000))
}

@Test func sameDayPrefersTheLargerMileage() throws {
    let rule = try makeRule(period: .months(12))
    let morning = try makeRecord(date: noon(2026, 5, 1), mileageKm: 90_000)
    let evening = try makeRecord(
        date: calendar.date(from: DateComponents(year: 2026, month: 5, day: 1, hour: 20))!, mileageKm: 89_000)
    let result = due(rule, records: [evening, morning], today: noon(2026, 6, 1))

    #expect(result.basis.mileageKm == 90_000)
}

// MARK: Дата срока

@Test func monthsAreAddedByCalendarNotByThirtyDays() throws {
    let cases: [(start: Date, months: Int, expected: CalendarDay)] = [
        (noon(2026, 1, 31), 1, day(2026, 2, 28)),
        (noon(2028, 1, 31), 1, day(2028, 2, 29)),  // високосный
        (noon(2026, 3, 15), 12, day(2027, 3, 15)),
        (noon(2028, 2, 29), 12, day(2029, 2, 28)),
    ]
    for (start, months, expected) in cases {
        let rule = try makeRule(period: .months(months), startDate: start)
        #expect(due(rule, today: start).dueDay == expected, "\(start) + \(months)")
    }
}

@Test func daysAreAddedAsCalendarDays() throws {
    let rule = try makeRule(period: .days(30), startDate: noon(2026, 1, 1))
    #expect(due(rule, today: noon(2026, 1, 1)).dueDay == day(2026, 1, 31))
}

@Test func mileageDueIsBasisPlusDistance() throws {
    let rule = try makeRule(period: nil, distanceKm: 10_000, startMileageKm: 87_000)
    let result = due(rule, today: noon(2026, 2, 1))

    #expect(result.dueMileageKm == 97_000)
    #expect(result.dueDay == nil)
}

// MARK: Статус по дате (срок 2026-04-10: старт 2026-01-10 + 90 дней)

@Test func statusByDateAroundTheBoundaries() throws {
    let rule = try makeRule(period: .days(90), startDate: noon(2026, 1, 10))
    #expect(due(rule, today: noon(2026, 1, 10)).dueDay == day(2026, 4, 10))
    let cases: [(today: Date, status: MaintenanceStatus)] = [
        (noon(2026, 3, 10), .ok),  // за 31 день
        (noon(2026, 3, 11), .dueSoon),  // за 30
        (noon(2026, 4, 9), .dueSoon),
        (noon(2026, 4, 10), .dueSoon),  // в день срока
        (noon(2026, 4, 11), .overdue),  // назавтра
        (noon(2027, 1, 1), .overdue),
    ]
    for (today, status) in cases {
        #expect(due(rule, today: today).status == status, "\(today)")
    }
}

@Test func timeOfDayDoesNotMoveTheDueDay() throws {
    let rule = try makeRule(period: .days(90), startDate: noon(2026, 1, 10))
    let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 4, day: 10, hour: 23, minute: 59))!
    let justAfterMidnight = calendar.date(from: DateComponents(year: 2026, month: 4, day: 11, hour: 0, minute: 1))!

    #expect(due(rule, today: lateEvening).status == .dueSoon)
    #expect(due(rule, today: justAfterMidnight).status == .overdue)
}

// MARK: Статус по пробегу (срок 97 000)

@Test func statusByMileageAroundTheBoundaries() throws {
    let rule = try makeRule(period: nil, distanceKm: 10_000, startMileageKm: 87_000)
    let cases: [(mileage: Int, status: MaintenanceStatus)] = [
        (87_000, .ok),
        (95_999, .ok),  // due − 1001
        (96_000, .dueSoon),  // due − 1000
        (96_999, .dueSoon),
        (97_000, .overdue),  // due
        (120_000, .overdue),
    ]
    for (mileage, status) in cases {
        #expect(due(rule, mileage: mileage, today: noon(2026, 2, 1)).status == status, "\(mileage)")
    }
}

// MARK: «Что раньше»

@Test func worstOfTheTwoDimensionsWins() throws {
    let rule = try makeRule(period: .months(12), distanceKm: 10_000, startDate: noon(2026, 1, 10))
    // Дата далеко (ok), пробег превышен.
    #expect(due(rule, mileage: 98_000, today: noon(2026, 2, 1)).status == .overdue)
    // Пробег в норме, дата просрочена.
    #expect(due(rule, mileage: 87_000, today: noon(2027, 3, 1)).status == .overdue)
    // Оба в норме.
    #expect(due(rule, mileage: 87_000, today: noon(2026, 2, 1)).status == .ok)
    // Дата ok, пробег «скоро» → «скоро».
    #expect(due(rule, mileage: 96_500, today: noon(2026, 2, 1)).status == .dueSoon)
}

// MARK: Derived state

@Test func removingAMistakenRecordRestoresTheStatus() throws {
    let vehicle = try makeVehicle(mileageKm: 87_000)
    let rule = try makeRule(period: nil, distanceKm: 10_000, startMileageKm: 87_000)
    let typo = try makeRecord(serviceType: .brakes, date: noon(2026, 2, 1), mileageKm: 900_000)

    let withTypo = due(rule, mileage: vehicle.currentMileageKm(records: [typo]), today: noon(2026, 3, 1))
    #expect(withTypo.status == .overdue)

    let withoutTypo = due(rule, mileage: vehicle.currentMileageKm(records: [ServiceRecord]()), today: noon(2026, 3, 1))
    #expect(withoutTypo.status == .ok)
}

// MARK: DST: срок попадает на день перехода

@Test func dueDayOnDaylightSavingTransitionDay() throws {
    let newYork = makeCalendar("America/New_York")
    let rule = try makeRule(period: .days(1), startDate: noon(2027, 3, 13, calendar: newYork))
    let result = due(rule, today: noon(2027, 3, 1, calendar: newYork), calendar: newYork)

    #expect(result.dueDay == day(2027, 3, 14))
    let reminders = MaintenanceSchedule.nextReminders(
        rules: [rule], vehicles: [try makeVehicle()], records: [], now: noon(2027, 3, 1, calendar: newYork),
        calendar: newYork)
    let fireAt = try #require(reminders.first?.fireAt)
    #expect(fireAt == DateComponents(year: 2027, month: 3, day: 14, hour: 10, minute: 0))
    #expect(fireAt.timeZone == nil)
    // 10:00 EDT = 14:00 UTC (в этот день пояс сместился с −5 на −4).
    #expect(newYork.date(from: fireAt) == isoDate("2027-03-14T14:00:00Z"))
}

@Test func dueDayOnEuropeanTransitionDay() throws {
    let berlin = makeCalendar("Europe/Berlin")
    let rule = try makeRule(period: .days(1), startDate: noon(2027, 3, 27, calendar: berlin))
    let result = due(rule, today: noon(2027, 3, 1, calendar: berlin), calendar: berlin)

    #expect(result.dueDay == day(2027, 3, 28))
    let reminders = MaintenanceSchedule.nextReminders(
        rules: [rule], vehicles: [try makeVehicle()], records: [], now: noon(2027, 3, 1, calendar: berlin),
        calendar: berlin)
    let fireAt = try #require(reminders.first?.fireAt)
    #expect(fireAt == DateComponents(year: 2027, month: 3, day: 28, hour: 10, minute: 0))
    // 10:00 CEST = 08:00 UTC.
    #expect(berlin.date(from: fireAt) == isoDate("2027-03-28T08:00:00Z"))
}

/// Переход «осень»: сутки длятся 25 часов. Сложение секундами (86 400) дало бы 23:00 того же дня.
@Test func dueDayAcrossFallBackTransition() throws {
    let newYork = makeCalendar("America/New_York")
    let rule = try makeRule(period: .days(1), startDate: noon(2027, 11, 6, calendar: newYork))
    let result = due(rule, today: noon(2027, 11, 1, calendar: newYork), calendar: newYork)

    #expect(result.dueDay == day(2027, 11, 7))
    let reminders = MaintenanceSchedule.nextReminders(
        rules: [rule], vehicles: [try makeVehicle()], records: [], now: noon(2027, 11, 1, calendar: newYork),
        calendar: newYork)
    // 10:00 EST = 15:00 UTC.
    let fireAt = try #require(reminders.first?.fireAt)
    #expect(makeCalendar("America/New_York").date(from: fireAt) == isoDate("2027-11-07T15:00:00Z"))
}

// MARK: Календарь пользователя с эпохами

@Test func japaneseCalendarDoesNotConfuseEras() throws {
    var japanese = Calendar(identifier: .japanese)
    japanese.timeZone = calendar.timeZone
    let rule = try makeRule(period: .months(12), startDate: noon(2026, 1, 10))
    let heisei = try makeRecord(date: noon(2018, 12, 1))
    let reiwa = try makeRecord(date: noon(2019, 6, 1))

    // Запись эпохи Хэйсэй: срок — июнь 2019, а не «31-й год Рэйва» (2049).
    let old = due(rule, records: [heisei], today: noon(2026, 1, 1), calendar: japanese)
    #expect(old.dueDay == day(2019, 12, 1))
    #expect(old.status == .overdue)
    // Поздняя запись выбирается по григорианскому порядку, а не по номеру года внутри эпохи.
    let both = due(rule, records: [heisei, reiwa], today: noon(2026, 1, 1), calendar: japanese)
    #expect(both.basis.date == reiwa.date)
    #expect(both.dueDay == day(2020, 6, 1))

    let reminders = MaintenanceSchedule.nextReminders(
        rules: [try makeRule(period: .days(30), startDate: noon(2026, 1, 1))], vehicles: [try makeVehicle()],
        records: [], now: noon(2026, 1, 2), calendar: japanese)
    #expect(reminders.first?.fireAt == DateComponents(year: 2026, month: 1, day: 31, hour: 10, minute: 0))
}

// MARK: Короткие интервалы

@Test func thresholdOfShortIntervalsIsHalfTheInterval() throws {
    let fortnight = try makeRule(period: .days(14), startDate: noon(2026, 1, 1))
    #expect(due(fortnight, today: noon(2026, 1, 1)).status == .ok)  // сразу после обслуживания
    #expect(due(fortnight, today: noon(2026, 1, 7)).status == .ok)  // за 8 дней при пороге 7
    #expect(due(fortnight, today: noon(2026, 1, 8)).status == .dueSoon)  // за 7 дней
    #expect(due(fortnight, today: noon(2026, 1, 15)).status == .dueSoon)
    #expect(due(fortnight, today: noon(2026, 1, 16)).status == .overdue)

    let month = try makeRule(period: .months(1), startDate: noon(2026, 1, 1))
    #expect(due(month, today: noon(2026, 1, 1)).status == .ok)  // 31 день до срока, порог 15

    let short = try makeRule(period: nil, distanceKm: 500, startMileageKm: 10_000)
    #expect(due(short, mileage: 10_000, today: noon(2026, 1, 1)).status == .ok)
    #expect(due(short, mileage: 10_249, today: noon(2026, 1, 1)).status == .ok)
    #expect(due(short, mileage: 10_250, today: noon(2026, 1, 1)).status == .dueSoon)
    #expect(due(short, mileage: 10_500, today: noon(2026, 1, 1)).status == .overdue)
}

@Test func daysUntilCountsCalendarDaysAcrossTransition() {
    let newYork = makeCalendar("America/New_York")
    #expect(day(2027, 3, 13).days(until: day(2027, 3, 15), calendar: newYork) == 2)
    #expect(day(2027, 3, 15).days(until: day(2027, 3, 13), calendar: newYork) == -2)
}
