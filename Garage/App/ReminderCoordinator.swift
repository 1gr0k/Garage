import Foundation
import GarageCore
import OSLog

private let logger = Logger(subsystem: "Garage", category: "Reminders")

/// Единственный запускатель пересчёта напоминаний (решение 15 плана этапа 12): склеивает сигналы дебаунсом и не
/// запускает пересчёты параллельно — сигнал во время пересчёта даёт ещё один после него.
///
/// Источники сигнала: сохранения в хранилище (`StoreChanges.saves`), переход приложения в `active`, смена
/// разрешения. Сам пересчёт — замыкание `recalculate` (composition root собирает его из `RescheduleReminders`,
/// «сегодня» и календаря), поэтому координатор не знает ни о хранилище, ни о системных уведомлениях.
@MainActor
final class ReminderCoordinator {
    private let debounce: Duration
    private let recalculate: @MainActor () async -> Void
    private var debounceTask: Task<Void, Never>?
    /// Номер последнего сигнала: отличает актуальный дебаунс от отменённого.
    private var generation = 0
    private var hasPendingSignal = false
    private var isRunning = false
    private var needsAnotherRun = false
    private var signalsTask: Task<Void, Never>?

    init(debounce: Duration = .milliseconds(500), recalculate: @escaping @MainActor () async -> Void) {
        self.debounce = debounce
        self.recalculate = recalculate
    }

    /// Подписывается на поток «данные сохранены». Повторный вызов заменяет подписку.
    func observe(_ signals: AsyncStream<Void>) {
        signalsTask?.cancel()
        signalsTask = Task { [weak self] in
            for await _ in signals {
                // Уведомление приходит на потоке сохранявшего; на главный актор переходим здесь.
                guard let self else { break }
                noteChange()
            }
        }
    }

    // Подписка снимается вместе с координатором: поток сам не кончится, и наблюдатель держал бы контейнер.
    isolated deinit {
        signalsTask?.cancel()
        debounceTask?.cancel()
    }

    /// Любое изменение данных или разрешения: пересчёт после паузы без новых сигналов.
    func noteChange() {
        debounceTask?.cancel()
        generation += 1
        let current = generation
        hasPendingSignal = true
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            // Устаревший дебаунс (пришёл новый сигнал) ничего не запускает.
            guard current == generation else { return }
            hasPendingSignal = false
            // С этого момента пересчёт нельзя отменить новым сигналом: он только запросит повтор (`needsAnotherRun`),
            // который выполнится в этой же задаче, не отменённой.
            debounceTask = nil
            await run()
        }
    }

    /// Прошло время, окно лимита сдвинулось, пользователь мог включить уведомления или сменить часовой пояс.
    func appBecameActive() {
        noteChange()
    }

    /// Для тестов: возвращается, когда нет ни ожидающего дебаунса, ни идущего пересчёта.
    func waitUntilIdle() async {
        while hasPendingSignal || isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func run() async {
        guard !isRunning else {
            // Пересчёт уже идёт: он повторится сам, когда закончит.
            needsAnotherRun = true
            return
        }
        isRunning = true
        repeat {
            needsAnotherRun = false
            await recalculate()
        } while needsAnotherRun
        isRunning = false
    }
}
