import Foundation
import GarageAPI
import GarageCore
import Testing

@testable import GarageSync

private func apiError(_ code: APIErrorCode, status: Int) -> SyncError {
    .api(status: status, APIError(code: code, message: "x"))
}

@Suite struct FailureMappingTests {
    @Test func syncErrorMapsToFailure() {
        #expect(apiError(.invalidSetupSecret, status: 401).toFailure() == .invalidSetupSecret)
        #expect(apiError(.unauthorized, status: 401).toFailure() == .unauthorized)
        #expect(apiError(.upgradeRequired, status: 426).toFailure() == .upgradeRequired)
        #expect(apiError(.cursorExpired, status: 410).toFailure() == .server(status: 410))
        #expect(SyncError.http(status: 502).toFailure() == .server(status: 502))
        #expect(SyncError.malformedResponse.toFailure() == .malformedResponse)
    }

    @Test func otherErrorsMapToFailure() {
        #expect(SyncFailure(URLError(.notConnectedToInternet)) == .network)
        #expect(
            SyncFailure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))) == .malformedResponse
        )
        #expect(SyncFailure(SyncFailure.keychain) == .keychain)
        #expect(SyncFailure(TestError.noScenario) == .other)
    }
}

@Suite struct DeviceRegistrarTests {
    @Test func registerSendsSecretAndReturnsToken() async throws {
        let transport = FakeHTTPTransport([try .golden("register-device-response", status: 201)])
        let registrar = SyncAPIDeviceRegistrar(makeTransport: { _ in transport })

        let token = try await registrar.register(
            serverURL: URL(string: "https://example.com")!, setupSecret: "correct-horse-battery-staple",
            deviceName: "iPhone Андрея")

        let request = try #require(await transport.requests.first)
        #expect(request.path == "/v1/devices")
        #expect(request.headers["Authorization"] == nil)
        #expect(
            try JSONValue(data: #require(request.body))
                == JSONValue(data: GoldenExamples.data("register-device-request")))
        #expect(token == "q83vEjRZk1T7mP0cX2wYb9LdAaNfU5hGsKiOtVeJr4I")
    }

    @Test func registerMapsErrorsToFailure() async throws {
        let body = APIErrorResponse(error: APIError(code: .invalidSetupSecret, message: "x"))
        let wrongSecret = SyncAPIDeviceRegistrar(
            makeTransport: { _ in FakeHTTPTransport([try! .json(body, status: 401)]) })
        let offline = SyncAPIDeviceRegistrar(
            makeTransport: { _ in FakeHTTPTransport([.fail(URLError(.cannotConnectToHost))]) })
        let url = URL(string: "https://example.com")!

        await #expect(throws: SyncFailure.invalidSetupSecret) {
            try await wrongSecret.register(serverURL: url, setupSecret: "no", deviceName: "x")
        }
        await #expect(throws: SyncFailure.network) {
            try await offline.register(serverURL: url, setupSecret: "no", deviceName: "x")
        }
    }
}

/// Транспорт, который «зависает» до отмены вызывающей задачи.
private actor HangingTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        didStart = true
        started?.resume()
        started = nil
        try await Task.sleep(for: .seconds(60))
        throw TestError.noScenario
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }
}

@Suite struct SyncCancellationTests {
    @Test func cancelDuringHungRequestThrowsAndSendsNothingMore() async throws {
        let store = InMemorySyncStore()
        await store.setCursor("5")
        let transport = HangingTransport()
        let engine = SyncEngine(store: store, client: SyncAPIClient(transport: transport, token: "t"))

        let task = Task { try await engine.sync() }
        await transport.waitUntilStarted()
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
        #expect(await store.cursor() == "5")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelBetweenPagesStopsBeforeNextRequest() async throws {
        let store = InMemorySyncStore()
        let gate = Gate()
        // Вторая страница отвечает успешно: без проверки отмены в цикле pull синхронизация
        // завершилась бы без ошибки, и тест гарантированно упал бы.
        let transport = FakeHTTPTransport([
            .before(
                { await gate.arriveAndWait() },
                try .json(PullResponse(changes: [], cursor: "1", hasMore: true))),
            try .json(emptyPull(cursor: "2")),
        ])
        let engine = makeEngine(store, transport)

        let task = Task { try await engine.sync() }
        // Отмена приходит строго пока первый запрос в полёте, до применения первой страницы.
        await gate.waitForArrival()
        task.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
        // Первая страница применена, вторая не запрошена.
        #expect(await store.cursor() == "1")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelOfOneCallerCancelsSharedRun() async throws {
        let store = InMemorySyncStore()
        let gate = Gate()
        let transport = FakeHTTPTransport([
            .before({ await gate.arriveAndWait() }, try .json(emptyPull(cursor: "1")))
        ])
        let engine = makeEngine(store, transport)

        let first = Task { try await engine.sync() }
        await gate.waitForArrival()
        let second = Task { try await engine.sync() }
        // Второй вызов присоединяется к общему прогону (или отменён ещё до этого): итог один и тот же.
        second.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) { try await second.value }
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await transport.requests.count == 1)
    }
}

/// Двусторонний барьер: тест ждёт, пока запрос «придёт», и сам решает, когда его отпустить.
private actor Gate {
    private var arrived = false
    private var opened = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrived = true
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        if opened { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func open() {
        opened = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
