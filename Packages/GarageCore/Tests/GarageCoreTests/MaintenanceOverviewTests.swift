import Foundation
import Testing

@testable import GarageCore

private let calendar = makeCalendar()
private let today = noon(2026, 6, 1)

private func statuses(
    _ rules: [MaintenanceRule], records: [ServiceRecord] = [], mileage: Int = 87_000
) throws -> [MaintenanceRuleStatus] {
    MaintenanceOverview.statuses(
        rules: rules, vehicle: try makeVehicle(mileageKm: mileage), records: records, today: today,
        calendar: calendar)
}

@Test func overviewIgnoresRulesOfOtherVehicles() throws {
    let mine = try makeRule()
    let foreign = try makeRule(vehicleID: otherVehicleID)

    #expect(try statuses([mine, foreign]).map(\.id) == [mine.id])
}

@Test func overviewPutsWorseStatusFirst() throws {
    let ok = try makeRule(period: .months(12), startDate: noon(2026, 5, 1))
    let soon = try makeRule(period: .months(12), startDate: noon(2025, 6, 20))
    let overdue = try makeRule(period: .months(12), startDate: noon(2025, 1, 1))

    let result = try statuses([ok, soon, overdue])

    #expect(result.map(\.id) == [overdue.id, soon.id, ok.id])
    #expect(result.map(\.due.status) == [.overdue, .dueSoon, .ok])
}

@Test func overviewOrdersEqualStatusByDueDayThenRulesWithoutTimeInterval() throws {
    let later = try makeRule(period: .months(12), startDate: noon(2025, 2, 1))
    let earlier = try makeRule(period: .months(12), startDate: noon(2025, 1, 1))
    // Оба просрочены: правило только по пробегу идёт после правил с датой срока.
    let byKm = try makeRule(period: nil, distanceKm: 1_000, startMileageKm: 80_000)

    let result = try statuses([byKm, later, earlier])

    #expect(result.map(\.id) == [earlier.id, later.id, byKm.id])
    #expect(result.allSatisfy { $0.due.status == .overdue })
}

@Test func overviewOrdersByMileageWhenNoDateAndIsDeterministic() throws {
    let far = try makeRule(period: nil, distanceKm: 5_000, startMileageKm: 80_000)
    let near = try makeRule(period: nil, distanceKm: 1_000, startMileageKm: 80_000)

    let first = try statuses([far, near])
    let second = try statuses([near, far])

    #expect(first.map(\.id) == [near.id, far.id])
    #expect(first == second)
}

@Test func overviewBreaksFullTiesByIdInAnyInputOrder() throws {
    let low = try makeRule(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, period: .months(12),
        startDate: noon(2025, 1, 1))
    let high = try makeRule(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, period: .months(12),
        startDate: noon(2025, 1, 1))

    #expect(try statuses([high, low]).map(\.id) == [low.id, high.id])
    #expect(try statuses([low, high]).map(\.id) == [low.id, high.id])
}

@Test func overviewUsesCurrentMileageFromRecords() throws {
    // Ручной пробег машины 87 000, но запись на 88 500 → «просрочено по пробегу».
    let rule = try makeRule(period: nil, distanceKm: 1_000, startMileageKm: 87_000)
    let record = try makeRecord(serviceType: .brakes, date: noon(2026, 5, 1), mileageKm: 88_500)

    #expect(try statuses([rule], records: [record]).first?.due.status == .overdue)
    #expect(try statuses([rule]).first?.due.status == .ok)
}
