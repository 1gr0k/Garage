import Foundation
import SwiftData

/// Подготовка хранилища при запуске приложения: контейнер, демо-данные, проверка схемы синхронизации.
public enum AppBootstrap {
    /// Идемпотентна. Выполняется вне главного потока.
    @concurrent
    public static func prepare(
        inMemory: Bool = false, defaults: UserDefaults = .standard
    ) async throws -> ModelContainer {
        let container = try GarageStore.makeContainer(inMemory: inMemory)
        try SampleSeeder.seedIfNeeded(container, defaults: defaults)
        try SyncSupport.prepare(container)
        return container
    }
}
