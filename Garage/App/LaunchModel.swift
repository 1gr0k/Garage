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

    private var isLaunching = false

    /// Запускает один раз: пока идёт запуск или всё готово, повторные вызовы (второе окно на iPad,
    /// повторный `.task`) ничего не делают. После ошибки вызов («Повторить») начинает заново.
    func launch() async {
        if case .ready = state { return }
        guard !isLaunching else { return }
        isLaunching = true
        defer { isLaunching = false }
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
