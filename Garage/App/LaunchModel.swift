import Foundation
import Observation

/// Запуск приложения: подготовка хранилища вне главного потока и сборка зависимостей.
@Observable
final class LaunchModel {
    enum State {
        case loading
        case ready(AppDependencies)
        case failed(String)
    }

    private(set) var state = State.loading
    private let bootstrap: () async throws -> AppDependencies

    init(bootstrap: @escaping () async throws -> AppDependencies) {
        self.bootstrap = bootstrap
    }

    /// Повторный вызов («Повторить») начинает запуск заново.
    func launch() async {
        state = .loading
        do {
            state = .ready(try await bootstrap())
        } catch is CancellationError {
            // Представление ушло с экрана: состояние не трогаем, следующий запуск начнёт заново.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
