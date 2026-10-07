import Foundation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "Garage", category: "Launch")
private let signposter = OSSignposter(logger: logger)

/// Подготовка хранилища при запуске приложения: контейнер, демо-данные, проверка схемы синхронизации.
public enum AppBootstrap {
    /// Идемпотентна. Выполняется вне главного потока.
    /// Длительность каждого шага пишется в лог (`subsystem: Garage, category: Launch`) и в signpost-интервалы.
    @concurrent
    public static func prepare(
        inMemory: Bool = false, defaults: UserDefaults = .standard
    ) async throws -> ModelContainer {
        let start = ContinuousClock.now
        let container = try measure("makeContainer") { try GarageStore.makeContainer(inMemory: inMemory) }
        try measure("seedIfNeeded") { try SampleSeeder.seedIfNeeded(container, defaults: defaults) }
        try measure("SyncSupport.prepare") { try SyncSupport.prepare(container) }
        logger.info("AppBootstrap total: \(milliseconds(since: start), privacy: .public) ms")
        return container
    }

    private static func measure<T>(_ step: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = signposter.beginInterval(step)
        let start = ContinuousClock.now
        defer { signposter.endInterval(step, interval) }
        do {
            let result = try body()
            logger.info(
                "AppBootstrap \(step.description, privacy: .public): \(milliseconds(since: start), privacy: .public) ms"
            )
            return result
        } catch {
            logger.error(
                """
                AppBootstrap \(step.description, privacy: .public) failed after \
                \(milliseconds(since: start), privacy: .public) ms: \(error)
                """)
            throw error
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}
