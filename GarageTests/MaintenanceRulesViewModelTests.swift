import Foundation
import GarageCore
import Testing

@testable import Garage

@MainActor
struct MaintenanceRulesViewModelTests {
    private let ruleID = UUID()

    private func makeModel(
        repository: FakeRuleRepository = FakeRuleRepository(),
        scheduler: FakeReminderScheduler = FakeReminderScheduler(),
        openSettings: @escaping () -> Void = {}
    ) -> MaintenanceRulesViewModel {
        MaintenanceRulesViewModel(rules: repository, scheduler: scheduler, openSettings: openSettings)
    }

    @Test func confirmedDeletionCallsThePortAndClearsTheDialog() async {
        let repository = FakeRuleRepository()
        let model = makeModel(repository: repository)
        model.pendingDeletion = ruleID

        await model.delete(id: ruleID)

        #expect(await repository.deleted == [ruleID])
        #expect(model.pendingDeletion == nil)
        #expect(!model.deleteFailed)
    }

    // Отмену диалога (`pendingDeletion = nil`) проверяет UI-тест `testSwipeDeleteRuleCancelThenConfirm`: это чистое
    // состояние вью, кода ViewModel в ней нет.

    @Test func failedDeletionSetsDeleteFailed() async {
        let repository = FakeRuleRepository()
        await repository.failDelete(with: TestFailure())
        let model = makeModel(repository: repository)

        await model.delete(id: ruleID)

        #expect(model.deleteFailed)
        #expect(!model.isDeleting)
    }

    @Test func notificationsDeniedFollowsAuthorization() async {
        let denied = makeModel(scheduler: FakeReminderScheduler(status: .denied))
        await denied.refreshAuthorization()
        #expect(denied.notificationsDenied)

        // Положительный контроль: не `denied` — баннера нет.
        for status in [ReminderAuthorization.authorized, .notDetermined] {
            let model = makeModel(scheduler: FakeReminderScheduler(status: status))
            await model.refreshAuthorization()
            #expect(!model.notificationsDenied)
        }
    }

    @Test func bannerDisappearsAfterPermissionIsGranted() async {
        let scheduler = FakeReminderScheduler(status: .denied)
        let model = makeModel(scheduler: scheduler)
        await model.refreshAuthorization()
        #expect(model.notificationsDenied)

        // Пользователь включил уведомления в Настройках и вернулся: статус перечитывается.
        await scheduler.setStatus(.authorized)
        await model.refreshAuthorization()
        #expect(!model.notificationsDenied)
    }

    @Test func rulesFromSyncOnFreshDeviceCanRequestPermissionAndTriggerRecalculation() async {
        let scheduler = FakeReminderScheduler()
        var changes = 0
        let model = MaintenanceRulesViewModel(
            rules: FakeRuleRepository(), scheduler: scheduler, openSettings: {}, permissionChanged: { changes += 1 })
        await model.refreshAuthorization()
        #expect(model.canRequestAuthorization)

        await model.requestAuthorization()

        #expect(await scheduler.requestCount == 1)
        #expect(!model.canRequestAuthorization)
        #expect(changes == 1)
    }

    @Test func requestIsOfferedOnlyWhenPermissionWasNeverAsked() async {
        for status in [ReminderAuthorization.authorized, .denied] {
            let model = makeModel(scheduler: FakeReminderScheduler(status: status))
            await model.refreshAuthorization()
            #expect(!model.canRequestAuthorization)
        }
    }

    @Test func refusalInTheRequestTurnsOnTheDeniedBanner() async {
        let model = makeModel(scheduler: FakeReminderScheduler(afterRequest: .denied))
        await model.refreshAuthorization()

        await model.requestAuthorization()

        #expect(model.notificationsDenied)
    }

    @Test func openSettingsCallsTheClosure() {
        var opened = 0
        let model = makeModel(openSettings: { opened += 1 })

        model.openSettings()

        #expect(opened == 1)
    }
}
