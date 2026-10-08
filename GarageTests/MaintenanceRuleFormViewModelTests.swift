import Foundation
import GarageCore
import Testing

@testable import Garage

@MainActor
struct MaintenanceRuleFormViewModelTests {
    private let vehicleID = Vehicle.samples[0].id
    private let today = Date(timeIntervalSince1970: 1_748_779_200)

    private func makeModel(
        mode: MaintenanceRuleFormViewModel.Mode? = nil, repository: FakeRuleRepository = FakeRuleRepository(),
        scheduler: FakeReminderScheduler = FakeReminderScheduler(), permissionChanged: @escaping () -> Void = {}
    ) -> MaintenanceRuleFormViewModel {
        MaintenanceRuleFormViewModel(
            mode: mode ?? .add(vehicleID: vehicleID, currentMileageKm: 87_400), today: today,
            addRule: AddMaintenanceRule(rules: repository), updateRule: UpdateMaintenanceRule(rules: repository),
            rules: repository, scheduler: scheduler, permissionChanged: permissionChanged)
    }

    private func makeOriginal() throws -> MaintenanceRule {
        try MaintenanceRule(
            vehicleID: vehicleID, serviceType: .oilChange, period: .months(12), distanceKm: 10_000,
            start: MaintenanceStart(date: today, mileageKm: 87_000))
    }

    @Test func newRuleStartsFromTodayAndCurrentMileage() {
        let model = makeModel()

        #expect(model.draft.startDate == today)
        #expect(model.draft.startMileageText == "87400")
        #expect(model.draft.usesPeriod)
        #expect(model.draft.periodValueText == "12")
        #expect(!model.isEditing)
    }

    @Test func invalidDraftFillsErrorsAndSavesNothing() async {
        let repository = FakeRuleRepository()
        let scheduler = FakeReminderScheduler()
        let model = makeModel(repository: repository, scheduler: scheduler)
        model.draft.usesPeriod = false

        let saved = await model.save()

        #expect(!saved)
        #expect(model.errors[.interval] != nil)
        #expect(!model.saveFailed)
        #expect(await repository.added.isEmpty)
        #expect(await scheduler.requestCount == 0)
    }

    @Test func editingAFieldClearsItsErrorAndTheIntervalError() async {
        let model = makeModel()
        model.draft.usesPeriod = false
        _ = await model.save()
        #expect(model.errors[.interval] != nil)

        model.clearError(for: .period)

        #expect(model.errors[.interval] == nil)
    }

    @Test func clearingAFieldRemovesItsOwnErrorOnly() async {
        let model = makeModel()
        model.draft.periodValueText = ""
        model.draft.startMileageText = ""
        _ = await model.save()
        #expect(model.errors[.period] != nil)
        #expect(model.errors[.startMileage] != nil)

        model.clearError(for: .period)

        #expect(model.errors[.period] == nil)
        #expect(model.errors[.startMileage] != nil)
    }

    @Test func firstRuleAsksForPermissionOnce() async {
        let repository = FakeRuleRepository()
        let scheduler = FakeReminderScheduler()
        var changes = 0
        let model = makeModel(repository: repository, scheduler: scheduler, permissionChanged: { changes += 1 })

        let saved = await model.save()
        #expect(saved)
        #expect(await repository.added.count == 1)
        #expect(await scheduler.requestCount == 1)
        #expect(changes == 1)

        // Положительный контроль: разрешение уже выдано — второе правило не спрашивает.
        let second = makeModel(repository: repository, scheduler: scheduler, permissionChanged: { changes += 1 })
        #expect(await second.save())
        #expect(await scheduler.requestCount == 1)
        #expect(changes == 1)
    }

    @Test func deniedPermissionIsNotAskedAgain() async {
        let scheduler = FakeReminderScheduler(status: .denied)
        let model = makeModel(scheduler: scheduler)

        #expect(await model.save())
        #expect(await scheduler.requestCount == 0)
    }

    @Test func refusalDoesNotCancelSaving() async {
        let repository = FakeRuleRepository()
        let scheduler = FakeReminderScheduler(afterRequest: .denied)
        let model = makeModel(repository: repository, scheduler: scheduler)

        let saved = await model.save()

        #expect(saved)
        #expect(await repository.added.count == 1)
        #expect(await scheduler.requestCount == 1)
    }

    @Test func mileageOnlyRuleDoesNotAskForPermission() async {
        let scheduler = FakeReminderScheduler()
        let model = makeModel(scheduler: scheduler)
        model.draft.usesPeriod = false
        model.draft.usesDistance = true
        model.draft.distanceText = "10000"

        #expect(await model.save())
        #expect(await scheduler.requestCount == 0)
    }

    @Test func storeFailureSetsSaveFailedWithoutAskingForPermission() async {
        let repository = FakeRuleRepository()
        await repository.failAdd(with: TestFailure())
        let scheduler = FakeReminderScheduler()
        let model = makeModel(repository: repository, scheduler: scheduler)

        let saved = await model.save()

        #expect(!saved)
        #expect(model.saveFailed)
        #expect(await scheduler.requestCount == 0)
    }

    @Test func vehicleDeletedMeanwhileSetsVehicleGone() async {
        let repository = FakeRuleRepository()
        await repository.failAdd(with: RepositoryError.vehicleNotFound(vehicleID))
        let model = makeModel(repository: repository)

        #expect(await model.save() == false)
        #expect(model.vehicleGone)
        #expect(!model.saveFailed)
    }

    @Test func editWithoutChangesDoesNotCallThePort() async throws {
        let repository = FakeRuleRepository()
        let model = makeModel(
            mode: .edit(original: try makeOriginal(), unrecognizedPeriod: nil), repository: repository)

        #expect(await model.save())
        #expect(await repository.updated.isEmpty)
    }

    @Test func editSendsChangedRuleAndKeepsIdentity() async throws {
        let original = try makeOriginal()
        let repository = FakeRuleRepository()
        let model = makeModel(mode: .edit(original: original, unrecognizedPeriod: nil), repository: repository)
        model.draft.periodValueText = "36"

        #expect(await model.save())

        let updated = await repository.updated
        #expect(updated.count == 1)
        #expect(updated[0].rule.id == original.id)
        #expect(updated[0].rule.period == .months(36))
        #expect(updated[0].period == .set)
    }

    @Test func editOfRuleWithUnknownPeriodKeepsItUntilFieldsAreTouched() async throws {
        let original = try MaintenanceRule(
            vehicleID: vehicleID, serviceType: .brakes, period: nil, distanceKm: 10_000,
            start: MaintenanceStart(date: today, mileageKm: 87_000))
        let repository = FakeRuleRepository()
        let model = makeModel(
            mode: .edit(original: original, unrecognizedPeriod: "weeks:2"), repository: repository)
        model.draft.distanceText = "20000"

        #expect(await model.save())

        let updated = await repository.updated
        #expect(updated.first?.period == .keepUnrecognized)
        #expect(updated.first?.rule.distanceKm == 20_000)
    }

    @Test func touchingThePeriodFieldsDropsTheUnknownPeriod() async throws {
        let original = try MaintenanceRule(
            vehicleID: vehicleID, serviceType: .brakes, period: nil, distanceKm: 10_000,
            start: MaintenanceStart(date: today, mileageKm: 87_000))
        let repository = FakeRuleRepository()
        let model = makeModel(
            mode: .edit(original: original, unrecognizedPeriod: "weeks:2"), repository: repository)
        model.draft.usesPeriod = true
        model.draft.periodValueText = "2"

        #expect(await model.save())

        let updated = await repository.updated
        #expect(updated.first?.period == .set)
        #expect(updated.first?.rule.period == .months(2))
    }

    @Test func ruleDeletedMeanwhileSetsRuleGone() async throws {
        let original = try makeOriginal()
        let repository = FakeRuleRepository()
        await repository.failUpdate(with: RepositoryError.ruleNotFound(original.id))
        let model = makeModel(mode: .edit(original: original, unrecognizedPeriod: nil), repository: repository)
        model.draft.periodValueText = "6"

        #expect(await model.save() == false)
        #expect(model.ruleGone)
    }

    @Test func deleteCallsThePortOnlyInEditMode() async throws {
        let original = try makeOriginal()
        let repository = FakeRuleRepository()

        #expect(await makeModel(repository: repository).delete() == false)
        #expect(await repository.deleted.isEmpty)

        let editing = makeModel(mode: .edit(original: original, unrecognizedPeriod: nil), repository: repository)
        #expect(await editing.delete())
        #expect(await repository.deleted == [original.id])
    }

    @Test func deleteFailureSetsDeleteFailed() async throws {
        let repository = FakeRuleRepository()
        await repository.failDelete(with: TestFailure())
        let model = makeModel(
            mode: .edit(original: try makeOriginal(), unrecognizedPeriod: nil), repository: repository)

        #expect(await model.delete() == false)
        #expect(model.deleteFailed)
    }
}
