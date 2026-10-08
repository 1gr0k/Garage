import Foundation
import GarageCore
import Observation

/// Состояние экрана правил машины: удаление правила (подтверждение и сбой), баннер «Уведомления выключены» и
/// включение уведомлений на устройстве, где правила пришли синхронизацией, а разрешение ещё не спрашивали.
@Observable
final class MaintenanceRulesViewModel {
    /// Правило, для которого показан диалог подтверждения; `nil` — диалога нет (в том числе после отмены).
    var pendingDeletion: MaintenanceRule.ID?
    /// Привязан к алерту вью, поэтому изменяем снаружи.
    var deleteFailed = false
    /// Последний прочитанный статус разрешения. До первого чтения — `authorized`: баннеров нет, пока статус неизвестен.
    private(set) var authorization = ReminderAuthorization.authorized
    private(set) var isDeleting = false

    private let rules: any MaintenanceRuleRepository
    private let scheduler: any ReminderScheduling
    private let openSettingsAction: () -> Void
    private let permissionChanged: () -> Void

    /// - Parameters:
    ///   - openSettings: открывает настройки уведомлений приложения (UIKit знает composition root).
    ///   - permissionChanged: после запроса разрешения: уведомления можно ставить, нужен пересчёт.
    init(
        rules: any MaintenanceRuleRepository, scheduler: any ReminderScheduling,
        openSettings: @escaping () -> Void, permissionChanged: @escaping () -> Void = {}
    ) {
        self.rules = rules
        self.scheduler = scheduler
        self.openSettingsAction = openSettings
        self.permissionChanged = permissionChanged
    }

    /// Пользователь запретил уведомления: правила работают в приложении, но уведомления не придут.
    var notificationsDenied: Bool { authorization == .denied }

    /// Разрешение ещё не спрашивали (например, правила пришли с другого устройства): уведомления не ставятся.
    var canRequestAuthorization: Bool { authorization == .notDetermined }

    /// Читает разрешение: при открытии экрана, при возвращении в приложение (пользователь мог изменить настройки)
    /// и после закрытия формы (она могла спросить разрешение).
    func refreshAuthorization() async {
        authorization = await scheduler.authorization()
    }

    /// Показывает системный запрос и просит пересчитать уведомления.
    func requestAuthorization() async {
        authorization = await scheduler.requestAuthorization()
        permissionChanged()
    }

    func openSettings() {
        openSettingsAction()
    }

    /// Удаляет подтверждённое правило. `id` передаёт вью из диалога: к моменту старта задачи `pendingDeletion`
    /// уже может быть сброшен закрытием диалога.
    func delete(id: MaintenanceRule.ID) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        pendingDeletion = nil
        do {
            try await rules.delete(id: id)
        } catch {
            deleteFailed = true
        }
    }
}
