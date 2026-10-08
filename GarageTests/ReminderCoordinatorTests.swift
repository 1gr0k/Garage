import Foundation
import Testing

@testable import Garage

@MainActor
private final class Recalculations {
    private(set) var started = 0
    private(set) var running = 0
    private(set) var maxRunning = 0
    /// Первый пересчёт встанет на барьер, пока тест его не откроет.
    var holdFirstAt: Gate?

    func recalculate() async {
        started += 1
        running += 1
        maxRunning = max(maxRunning, running)
        if started == 1, let holdFirstAt { await holdFirstAt.arriveAndWait() }
        running -= 1
    }
}

@MainActor
struct ReminderCoordinatorTests {
    private let debounce = Duration.milliseconds(30)

    private func makeCoordinator(_ recalculations: Recalculations) -> ReminderCoordinator {
        ReminderCoordinator(debounce: debounce) { await recalculations.recalculate() }
    }

    /// Положительный контроль к склейке: один сигнал — ровно один пересчёт.
    @Test func oneSignalMakesExactlyOneRecalculation() async {
        let recalculations = Recalculations()
        let coordinator = makeCoordinator(recalculations)

        coordinator.noteChange()
        await coordinator.waitUntilIdle()

        #expect(recalculations.started == 1)
    }

    @Test func signalsWithinTheDebounceWindowAreMergedIntoOneRecalculation() async {
        let recalculations = Recalculations()
        let coordinator = makeCoordinator(recalculations)

        coordinator.noteChange()
        coordinator.noteChange()
        coordinator.noteChange()
        await coordinator.waitUntilIdle()

        #expect(recalculations.started == 1)
    }

    @Test func signalDuringARecalculationRunsAnotherOneAfterItNotInParallel() async {
        let recalculations = Recalculations()
        let gate = Gate()
        recalculations.holdFirstAt = gate
        let coordinator = makeCoordinator(recalculations)

        coordinator.noteChange()
        await gate.waitForArrival()
        coordinator.noteChange()
        // Дебаунс второго сигнала истёк, а первый пересчёт всё ещё держит барьер.
        try? await Task.sleep(for: debounce * 4)
        #expect(recalculations.started == 1)

        await gate.open()
        await coordinator.waitUntilIdle()

        #expect(recalculations.started == 2)
        #expect(recalculations.maxRunning == 1)
    }

    /// Повторный пересчёт идёт не в отменённой задаче: отмена в нём (проверка, `sleep`) не должна его ронять.
    @Test func followUpRecalculationIsNotCancelledByTheSignalThatRequestedIt() async {
        let gate = Gate()
        var completed = 0
        var attempt = 0
        let coordinator = ReminderCoordinator(debounce: debounce) {
            attempt += 1
            if attempt == 1 { await gate.arriveAndWait() }
            do {
                try Task.checkCancellation()
                completed += 1
            } catch {}
        }

        coordinator.noteChange()
        await gate.waitForArrival()
        coordinator.noteChange()
        try? await Task.sleep(for: debounce * 4)
        await gate.open()
        await coordinator.waitUntilIdle()

        #expect(attempt == 2)
        #expect(completed == 2)
    }

    @Test func appBecomingActiveRecalculates() async {
        let recalculations = Recalculations()
        let coordinator = makeCoordinator(recalculations)

        coordinator.appBecameActive()
        await coordinator.waitUntilIdle()

        #expect(recalculations.started == 1)
    }

    @Test func storeSignalsStartARecalculation() async {
        let recalculations = Recalculations()
        let coordinator = makeCoordinator(recalculations)
        let (signals, continuation) = AsyncStream<Void>.makeStream()
        coordinator.observe(signals)

        continuation.yield()
        // Сигнал доходит до координатора асинхронно: ждём, пока пересчёт начнётся.
        for _ in 0..<200 where recalculations.started == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await coordinator.waitUntilIdle()
        continuation.finish()

        #expect(recalculations.started == 1)
    }

    /// Без сигнала пересчёта нет.
    @Test func nothingHappensWithoutASignal() async {
        let recalculations = Recalculations()
        let coordinator = makeCoordinator(recalculations)

        await coordinator.waitUntilIdle()
        try? await Task.sleep(for: debounce * 3)

        #expect(recalculations.started == 0)
    }
}
