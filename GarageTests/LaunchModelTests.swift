import GarageStorage
import Testing

@testable import Garage

@MainActor
struct LaunchModelTests {
    @Test func successfulBootstrapMakesModelReady() async throws {
        let model = LaunchModel { AppDependencies(container: try await AppBootstrap.prepare(inMemory: true)) }

        await model.launch()

        guard case .ready = model.state else {
            Issue.record("expected .ready, got \(model.state)")
            return
        }
    }

    @Test func failedBootstrapShowsErrorAndRetryRecovers() async throws {
        var shouldFail = true
        let model = LaunchModel {
            if shouldFail { throw TestFailure() }
            return AppDependencies(container: try await AppBootstrap.prepare(inMemory: true))
        }

        await model.launch()
        guard case .failed = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }

        shouldFail = false
        await model.launch()
        guard case .ready = model.state else {
            Issue.record("expected .ready after retry, got \(model.state)")
            return
        }
    }
}
