import Foundation
import Testing

@testable import GarageCore

private func validDraft() -> MaintenanceRuleDraft {
    MaintenanceRuleDraft(
        usesPeriod: true, periodValueText: "12", periodUnit: .months, startDate: noon(2026, 1, 10),
        startMileageText: "87000")
}

// MARK: AddMaintenanceRule

@Test func addRuleDoesNotReachRepositoryOnInvalidDraft() async {
    let repository = FakeRuleRepository()
    var draft = validDraft()
    draft.periodValueText = ""

    await #expect(throws: MaintenanceRuleDraft.Errors.self) {
        try await AddMaintenanceRule(rules: repository).execute(draft: draft, vehicleID: testVehicleID)
    }
    #expect(repository.added.isEmpty)
}

@Test func addRulePassesTheRule() async throws {
    let repository = FakeRuleRepository()
    try await AddMaintenanceRule(rules: repository).execute(draft: validDraft(), vehicleID: testVehicleID)

    #expect(repository.added.count == 1)
    #expect(repository.added[0].vehicleID == testVehicleID)
    #expect(repository.added[0].period == .months(12))
}

@Test func addRulePropagatesRepositoryError() async {
    let repository = FakeRuleRepository()
    repository.error = RepositoryError.vehicleNotFound(testVehicleID)

    await #expect(throws: RepositoryError.vehicleNotFound(testVehicleID)) {
        try await AddMaintenanceRule(rules: repository).execute(draft: validDraft(), vehicleID: testVehicleID)
    }
}

// MARK: UpdateMaintenanceRule

@Test func updateRuleDoesNotReachRepositoryOnInvalidDraft() async throws {
    let repository = FakeRuleRepository()
    let original = try makeRule()
    var draft = MaintenanceRuleDraft(rule: original)
    draft.usesPeriod = false

    await #expect(throws: MaintenanceRuleDraft.Errors.self) {
        try await UpdateMaintenanceRule(rules: repository).execute(draft: draft, original: original)
    }
    #expect(repository.updated.isEmpty)
}

@Test func updateRuleKeepsIdentity() async throws {
    let repository = FakeRuleRepository()
    let original = try makeRule(period: .months(12))
    var draft = MaintenanceRuleDraft(rule: original)
    draft.periodValueText = "6"

    try await UpdateMaintenanceRule(rules: repository).execute(draft: draft, original: original)

    #expect(repository.updated.count == 1)
    #expect(repository.updated[0].id == original.id)
    #expect(repository.updated[0].vehicleID == original.vehicleID)
    #expect(repository.updated[0].period == .months(6))
}

@Test func updateRuleSkipsRepositoryWhenNothingChanged() async throws {
    let repository = FakeRuleRepository()
    let original = try makeRule(serviceType: .other("  Антифриз "), period: .months(12), distanceKm: 10_000)

    try await UpdateMaintenanceRule(rules: repository).execute(
        draft: MaintenanceRuleDraft(rule: original), original: original)

    #expect(repository.updated.isEmpty)
}

// Сырой незнакомый период (`"weeks:2"`) живёт, пока поля интервала по времени не тронуты явно
// (решение 9e плана этапа 12, открытый вопрос S).

private func ruleWithUnrecognizedPeriod() throws -> MaintenanceRule {
    try makeRule(period: nil, distanceKm: 10_000)
}

@Test func updateRuleKeepsUnrecognizedPeriodWhileTheFieldIsUntouched() async throws {
    let repository = FakeRuleRepository()
    let original = try ruleWithUnrecognizedPeriod()
    var draft = MaintenanceRuleDraft(rule: original, unrecognizedPeriod: "weeks:2")
    draft.distanceText = "15000"

    try await UpdateMaintenanceRule(rules: repository).execute(draft: draft, original: original)

    #expect(repository.updated.map(\.distanceKm) == [15_000])
    #expect(repository.periodChanges == [.keepUnrecognized])
}

@Test func updateRuleWithUnrecognizedPeriodAndNoEditsSkipsRepository() async throws {
    let repository = FakeRuleRepository()
    let original = try ruleWithUnrecognizedPeriod()

    try await UpdateMaintenanceRule(rules: repository).execute(
        draft: MaintenanceRuleDraft(rule: original, unrecognizedPeriod: "weeks:2"), original: original)

    #expect(repository.updated.isEmpty)
}

/// Положительный контроль: любое явное действие с полем интервала по времени снимает «не изменён» — даже если
/// итоговое правило равно исходному (период включили и выключили).
@Test func updateRuleTouchingThePeriodFieldClearsTheRawPeriodEvenWithoutChangingTheRule() async throws {
    let repository = FakeRuleRepository()
    let original = try ruleWithUnrecognizedPeriod()
    var draft = MaintenanceRuleDraft(rule: original, unrecognizedPeriod: "weeks:2")
    draft.usesPeriod = true
    draft.usesPeriod = false
    #expect(!draft.keepsUnrecognizedPeriod)

    try await UpdateMaintenanceRule(rules: repository).execute(draft: draft, original: original)

    #expect(repository.updated == [original])
    #expect(repository.periodChanges == [.set])
}

@Test func updateRuleSettingAKnownPeriodReplacesTheRawOne() async throws {
    let repository = FakeRuleRepository()
    let original = try ruleWithUnrecognizedPeriod()
    var draft = MaintenanceRuleDraft(rule: original, unrecognizedPeriod: "weeks:2")
    draft.usesPeriod = true
    draft.periodValueText = "6"
    draft.periodUnit = .months

    try await UpdateMaintenanceRule(rules: repository).execute(draft: draft, original: original)

    #expect(repository.updated.map(\.period) == [.months(6)])
    #expect(repository.periodChanges == [.set])
}

/// Правка без сырого периода: поле «не тронуто» не существует, порт всегда получает `set`.
@Test func updateRuleWithoutRawPeriodAlwaysSets() async throws {
    let repository = FakeRuleRepository()
    let original = try makeRule(period: .months(12))
    var draft = MaintenanceRuleDraft(rule: original)
    #expect(!draft.keepsUnrecognizedPeriod)
    draft.periodValueText = "6"

    try await UpdateMaintenanceRule(rules: repository).execute(draft: draft, original: original)

    #expect(repository.periodChanges == [.set])
}

@Test func updateRulePropagatesRuleNotFound() async throws {
    let repository = FakeRuleRepository()
    let original = try makeRule()
    repository.error = RepositoryError.ruleNotFound(original.id)
    var draft = MaintenanceRuleDraft(rule: original)
    draft.periodValueText = "6"

    await #expect(throws: RepositoryError.ruleNotFound(original.id)) {
        try await UpdateMaintenanceRule(rules: repository).execute(draft: draft, original: original)
    }
}

// MARK: RescheduleReminders

private func makeSnapshot() throws -> MaintenanceSnapshot {
    MaintenanceSnapshot(
        vehicles: [try makeVehicle()], records: [],
        rules: [
            try makeRule(period: .days(30), startDate: noon(2026, 1, 1)),
            try makeRule(serviceType: .brakes, period: .days(60), startDate: noon(2026, 1, 1)),
        ])
}

@Test func rescheduleHandsExactlyTheWindowToTheScheduler() async throws {
    let snapshot = FakeSnapshotReader()
    snapshot.data = try makeSnapshot()
    let scheduler = FakeReminderScheduler(status: .authorized)
    let now = noon(2026, 1, 2)

    try await RescheduleReminders(snapshot: snapshot, scheduler: scheduler).execute(now: now, calendar: makeCalendar())

    let expected = MaintenanceSchedule.nextReminders(
        rules: snapshot.data.rules, vehicles: snapshot.data.vehicles, records: [], now: now, calendar: makeCalendar())
    #expect(expected.count == 2)
    #expect(scheduler.replaced == [expected])
}

@Test func rescheduleWithEmptyWindowStillReplacesSoStaleRequestsAreRemoved() async throws {
    let scheduler = FakeReminderScheduler(status: .authorized)

    try await RescheduleReminders(snapshot: FakeSnapshotReader(), scheduler: scheduler)
        .execute(now: noon(2026, 1, 2), calendar: makeCalendar())

    #expect(scheduler.replaced == [[]])
}

@Test func rescheduleSnapshotFailureLeavesTheSchedulerAlone() async {
    let snapshot = FakeSnapshotReader()
    snapshot.error = TestFailure()
    let scheduler = FakeReminderScheduler(status: .authorized)

    await #expect(throws: TestFailure.self) {
        try await RescheduleReminders(snapshot: snapshot, scheduler: scheduler)
            .execute(now: noon(2026, 1, 2), calendar: makeCalendar())
    }
    #expect(scheduler.replaced.isEmpty)
}

@Test func rescheduleSchedulerFailureIsPropagated() async throws {
    let snapshot = FakeSnapshotReader()
    snapshot.data = try makeSnapshot()
    let scheduler = FakeReminderScheduler(status: .authorized)
    scheduler.error = TestFailure()

    await #expect(throws: TestFailure.self) {
        try await RescheduleReminders(snapshot: snapshot, scheduler: scheduler)
            .execute(now: noon(2026, 1, 2), calendar: makeCalendar())
    }
}

@Test(arguments: [ReminderAuthorization.notDetermined, .denied])
func rescheduleWithoutPermissionTouchesNeitherSnapshotNorScheduler(status: ReminderAuthorization) async throws {
    let snapshot = FakeSnapshotReader()
    snapshot.data = try makeSnapshot()
    let scheduler = FakeReminderScheduler(status: status)

    try await RescheduleReminders(snapshot: snapshot, scheduler: scheduler)
        .execute(now: noon(2026, 1, 2), calendar: makeCalendar())

    #expect(snapshot.readCount == 0)
    #expect(scheduler.replaced.isEmpty)
    #expect(scheduler.requestCount == 0)
}

/// Положительный контроль к предыдущему: тот же сценарий с разрешением доходит до `replaceAll` ровно раз.
@Test func rescheduleWithPermissionReplacesOnce() async throws {
    let snapshot = FakeSnapshotReader()
    snapshot.data = try makeSnapshot()
    let scheduler = FakeReminderScheduler(status: .authorized)

    try await RescheduleReminders(snapshot: snapshot, scheduler: scheduler)
        .execute(now: noon(2026, 1, 2), calendar: makeCalendar())

    #expect(snapshot.readCount == 1)
    #expect(scheduler.replaced.count == 1)
    #expect(scheduler.requestCount == 0)
}
