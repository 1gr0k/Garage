import Foundation
import GarageStorage
import Testing

@testable import Garage

@MainActor
struct LaunchModelTests {
    /// In-memory хранилище, свои UserDefaults и фейковые учётные данные: тест не трогает данные хост-приложения.
    private func makeDependencies() async throws -> AppDependencies {
        let defaults = UserDefaults(suiteName: "LaunchModelTests-\(UUID().uuidString)")!
        let container = try await AppBootstrap.prepare(inMemory: true, defaults: defaults)
        return AppDependencies(container: container, credentials: FakeCredentials())
    }

    @Test func successfulBootstrapMakesModelReady() async throws {
        let model = LaunchModel { try await makeDependencies() }

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
            return try await makeDependencies()
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

    @Test func launchWhenReadyKeepsExistingDependencies() async throws {
        var bootstrapCount = 0
        let model = LaunchModel {
            bootstrapCount += 1
            return try await makeDependencies()
        }

        await model.launch()
        guard case .ready(let first) = model.state else {
            Issue.record("expected .ready, got \(model.state)")
            return
        }
        await model.launch()

        #expect(bootstrapCount == 1)
        guard case .ready(let second) = model.state else {
            Issue.record("expected .ready, got \(model.state)")
            return
        }
        #expect(first === second)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentLaunchesBootstrapOnce() async throws {
        var bootstrapCount = 0
        let gate = Gate()
        let model = LaunchModel {
            bootstrapCount += 1
            await gate.arriveAndWait()
            return try await makeDependencies()
        }

        let first = Task { await model.launch() }
        await gate.waitForArrival()
        await model.launch()
        await gate.open()
        await first.value

        #expect(bootstrapCount == 1)
        guard case .ready = model.state else {
            Issue.record("expected .ready, got \(model.state)")
            return
        }
    }
}
