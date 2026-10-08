import Foundation
import Testing

@testable import GarageCore

private func validDraft() -> MaintenanceRuleDraft {
    MaintenanceRuleDraft(
        serviceTypeChoice: .oilChange, usesPeriod: true, periodValueText: "12", periodUnit: .months,
        usesDistance: true, distanceText: "10 000", startDate: noon(2026, 1, 10), startMileageText: "87 400")
}

private func errors(_ draft: MaintenanceRuleDraft) -> [MaintenanceRuleDraft.Field: MaintenanceRuleDraft.FieldError] {
    do {
        _ = try draft.makeRule(vehicleID: testVehicleID)
        return [:]
    } catch {
        return error.fields
    }
}

@Test func validDraftMakesTheRule() throws {
    let id = UUID()
    let rule = try validDraft().makeRule(id: id, vehicleID: testVehicleID)

    #expect(rule.id == id)
    #expect(rule.vehicleID == testVehicleID)
    #expect(rule.serviceType == .oilChange)
    #expect(rule.period == .months(12))
    #expect(rule.distanceKm == 10_000)
    #expect(rule.start == (try MaintenanceStart(date: noon(2026, 1, 10), mileageKm: 87_400)))
}

@Test func unitSelectsDaysOrMonths() throws {
    var draft = validDraft()
    draft.periodUnit = .days
    #expect(try draft.makeRule(vehicleID: testVehicleID).period == .days(12))
}

@Test func noIntervalSelectedIsAnIntervalError() {
    var draft = validDraft()
    draft.usesPeriod = false
    draft.usesDistance = false
    #expect(errors(draft) == [.interval: .invalid(.noInterval)])
}

@Test func disabledIntervalIgnoresItsText() throws {
    var draft = validDraft()
    draft.usesDistance = false
    draft.distanceText = "мусор"
    #expect(try draft.makeRule(vehicleID: testVehicleID).distanceKm == nil)
}

@Test func periodFieldErrors() {
    var draft = validDraft()
    for (text, expected) in [
        ("", MaintenanceRuleDraft.FieldError.required), ("abc", .notANumber), ("0", .invalid(.periodOutOfRange(0))),
        ("121", .invalid(.periodOutOfRange(121))),
    ] {
        draft.periodValueText = text
        #expect(errors(draft) == [.period: expected], "\(text)")
    }
    draft.periodUnit = .days
    draft.periodValueText = "121"
    #expect(errors(draft).isEmpty)
    draft.periodValueText = "3651"
    #expect(errors(draft) == [.period: .invalid(.periodOutOfRange(3651))])
}

@Test func distanceFieldErrors() {
    var draft = validDraft()
    for (text, expected) in [
        ("", MaintenanceRuleDraft.FieldError.required), ("x", .notANumber), ("0", .invalid(.distanceOutOfRange(0))),
        ("10000001", .invalid(.distanceOutOfRange(10_000_001))),
    ] {
        draft.distanceText = text
        #expect(errors(draft) == [.distance: expected], "\(text)")
    }
}

@Test func otherServiceTypeNeedsText() throws {
    var draft = validDraft()
    draft.serviceTypeChoice = .other
    draft.otherServiceTypeText = "  "
    #expect(errors(draft) == [.otherServiceType: .required])
    draft.otherServiceTypeText = "  Антифриз "
    #expect(try draft.makeRule(vehicleID: testVehicleID).serviceType == .other("Антифриз"))
}

@Test func startMileageIsChecked() {
    var draft = validDraft()
    draft.startMileageText = ""
    #expect(errors(draft) == [.startMileage: .required])
    draft.startMileageText = "-5"
    #expect(errors(draft)[.startMileage] == .invalid(.negativeMileage(-5)))
}

@Test func allProblemsAreReportedAtOnce() {
    var draft = validDraft()
    draft.periodValueText = "0"
    draft.distanceText = ""
    draft.startMileageText = "x"
    #expect(Set(errors(draft).keys) == [.period, .distance, .startMileage])
}

@Test func draftFromRuleRoundTrips() throws {
    for rule in [
        try makeRule(period: .months(12), distanceKm: 10_000),
        try makeRule(serviceType: .other("Антифриз"), period: .days(30), distanceKm: nil),
        try makeRule(serviceType: .brakes, period: nil, distanceKm: 50_000),
    ] {
        #expect(try MaintenanceRuleDraft(rule: rule).makeRule(id: rule.id, vehicleID: rule.vehicleID) == rule)
    }
}
