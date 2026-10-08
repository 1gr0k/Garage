import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData
import Testing

@testable import GarageStorage

// Правила через настоящий `SyncEngine` и `FakeSyncServer`, сигнал сохранения и лог синхронизации (часть B1).

private func sync(_ container: ModelContainer, with server: any HTTPTransport) async throws -> SyncReport {
    let store = SwiftDataSyncStore(modelContainer: container)
    return try await SyncEngine(
        store: store, client: SyncAPIClient(transport: server, token: "t"), receipts: store
    ).sync()
}

private func makeRule(vehicleID: UUID, distanceKm: Int = 10_000) throws -> MaintenanceRule {
    try MaintenanceRule(
        vehicleID: vehicleID, serviceType: .oilChange, period: .months(12), distanceKm: distanceKm,
        start: MaintenanceStart(date: Date(timeIntervalSince1970: 1_700_000_000), mileageKm: 87_000))
}

private func rules(in container: ModelContainer) throws -> [MaintenanceRuleEntity] {
    try ModelContext(container).fetch(FetchDescriptor<MaintenanceRuleEntity>())
}

@Suite struct RuleSyncEndToEndTests {
    @Test func ruleGoesToServerAndToASecondDeviceAndItsEditAndDeletionFollow() async throws {
        let server = FakeSyncServer()
        let first = try GarageStore.makeContainer(inMemory: true)
        let second = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: first)
        let rule = try makeRule(vehicleID: vehicle.id)
        try RuleLog.add(rule, in: first)
        try SyncSupport.prepare(first)
        try SyncSupport.prepare(second)

        let pushReport = try await sync(first, with: server)
        _ = try await sync(second, with: server)

        #expect(pushReport.pushed == 2)
        #expect(await server.liveCount(.maintenanceRule) == 1)
        #expect(try rules(in: second).first?.toDomain() == rule)

        var edited = rule
        try edited.updateInterval(period: .months(6), distanceKm: nil)
        try RuleLog.update(edited, period: .set, in: first)
        _ = try await sync(first, with: server)
        _ = try await sync(second, with: server)
        #expect(try rules(in: second).first?.toDomain() == edited)

        try RuleLog.delete(id: rule.id, in: first)
        _ = try await sync(first, with: server)
        _ = try await sync(second, with: server)
        #expect(await server.liveCount(.maintenanceRule) == 0)
        #expect(try rules(in: second).isEmpty)
    }

    @Test func deletingTheVehicleOnOneDeviceRemovesTheRuleOnTheOther() async throws {
        let server = FakeSyncServer()
        let first = try GarageStore.makeContainer(inMemory: true)
        let second = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: first)
        try RuleLog.add(try makeRule(vehicleID: vehicle.id), in: first)
        try SyncSupport.prepare(first)
        try SyncSupport.prepare(second)
        _ = try await sync(first, with: server)
        _ = try await sync(second, with: server)
        #expect(try rules(in: second).count == 1)

        try VehicleLog.delete(id: vehicle.id, in: first)
        _ = try await sync(first, with: server)
        _ = try await sync(second, with: server)

        #expect(try rules(in: second).isEmpty)
        #expect(await server.liveCount(.maintenanceRule) == 0)
    }

    /// Сценарий апгрейда: правило, пропущенное заглушкой части S (в хранилище его нет, курсор ушёл дальше), приходит
    /// заново после роста `schemaVersion`, потому что тот сбрасывает курсор.
    @Test func schemaBumpBringsBackARuleTheStubSkipped() async throws {
        let server = FakeSyncServer()
        let writer = try GarageStore.makeContainer(inMemory: true)
        let device = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        try VehicleLog.add(vehicle, in: writer)
        let rule = try makeRule(vehicleID: vehicle.id)
        try RuleLog.add(rule, in: writer)
        try SyncSupport.prepare(writer)
        try SyncSupport.prepare(device)
        _ = try await sync(writer, with: server)
        _ = try await sync(device, with: server)
        // Заглушка пропустила правило: в хранилище устройства его нет, а курсор уже дальше.
        let context = ModelContext(device)
        for entity in try context.fetch(FetchDescriptor<MaintenanceRuleEntity>()) { context.delete(entity) }
        try SyncState.current(in: context).schemaVersion = GarageStore.schemaVersion - 1
        try context.save()
        #expect(try rules(in: device).isEmpty)

        try SyncSupport.prepare(device)
        _ = try await sync(device, with: server)

        #expect(try rules(in: device).first?.toDomain() == rule)
    }
}

@Suite struct StoreChangesTests {
    /// Сигнал приходит после записи из каждого пути: `ServiceLog`, `VehicleLog`, `RuleLog`, `SwiftDataSyncStore.apply`.
    @Test func signalArrivesAfterEveryWritePath() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        let store = SwiftDataSyncStore(modelContainer: container)
        let other = Vehicle.samples[1]
        let rule = try makeRule(vehicleID: vehicle.id)
        let writes: [(String, () async throws -> Void)] = [
            ("VehicleLog", { try VehicleLog.add(vehicle, in: container) }),
            (
                "ServiceLog",
                { try ServiceLog.add(try makeSyncRecord(for: vehicle), toVehicleWithID: vehicle.id, in: container) }
            ),
            ("RuleLog", { try RuleLog.add(rule, in: container) }),
            (
                "SwiftDataSyncStore.apply",
                {
                    try await store.apply(
                        RemoteChange(version: 1, operation: .upsert(.vehicle(other))),
                        for: EntityRef(kind: .vehicle, id: other.id))
                }
            ),
        ]
        for (name, write) in writes {
            let signals = StoreChanges.saves(of: container)
            try await write()
            #expect(await receivesSignal(signals, within: .seconds(5)), "no save signal after \(name)")
        }
    }

    /// Положительный контроль: без записи сигнала нет, а запись в другой контейнер не считается.
    @Test func noSignalWithoutAWriteInThisContainer() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let elsewhere = try GarageStore.makeContainer(inMemory: true)
        let signals = StoreChanges.saves(of: container)

        try VehicleLog.add(Vehicle.samples[0], in: elsewhere)

        #expect(await receivesSignal(signals, within: .milliseconds(500)) == false)
    }

    /// Поток подписывается при создании, поэтому сигнал от записи до чтения не теряется (буфер).
    private func receivesSignal(_ signals: AsyncStream<Void>, within timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = signals.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

/// Транспорт, на каждый push отвечающий незнакомым статусом (`unrecognized`), на pull — пустой страницей.
private actor UnrecognizedStatusTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.method == "POST" {
            let pushed = try APICoding.makeDecoder().decode(PushRequest.self, from: request.body ?? Data())
            let results = pushed.changes.map { #"{"changeID":"\#($0.changeID.uuidString)","status":"quantum"}"# }
            return HTTPResponse(status: 200, body: Data(#"{"results":[\#(results.joined(separator: ","))]}"#.utf8))
        }
        let pull = PullResponse(changes: [], cursor: "0", hasMore: false)
        return HTTPResponse(status: 200, body: try APICoding.makeEncoder().encode(pull))
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
}

private final class FixedCredentials: SyncCredentialsStore, @unchecked Sendable {
    func readToken() -> String? { "t" }
    func saveToken(_ token: String) throws {}
    func deleteToken() throws {}
    func readServerURL() -> URL? { URL(string: "https://example.com") }
    func saveServerURL(_ url: URL) {}
    func deleteServerURL() {}
}

@Suite struct SyncDiagnosticsTests {
    /// T3, R12: незнакомый исход пишется в лог при **каждом** прогоне, а изменение остаётся в очереди.
    @Test func unrecognizedOutcomeIsLoggedOnEveryRunAndTheChangeStaysQueued() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        try VehicleLog.add(Vehicle.samples[0], in: container)
        let log = LogBox()
        let service = SwiftDataSyncService(
            container: container, credentials: FixedCredentials(),
            makeTransport: { _ in UnrecognizedStatusTransport() }, logNotice: { log.append($0) })

        _ = try await service.sync()
        #expect(log.lines.count == 1)
        _ = try await service.sync()

        #expect(log.lines.count == 2)
        #expect(log.lines.allSatisfy { $0.contains("quantum") && $0.contains("vehicle:") })
        #expect(try await service.status().pendingCount == 1)
    }

    /// Положительный контроль: без незнакомых исходов лог пуст.
    @Test func nothingIsLoggedWhenEverythingIsRecognized() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let log = LogBox()
        let service = SwiftDataSyncService(
            container: container, credentials: FixedCredentials(),
            makeTransport: { _ in FakeSyncServer() }, logNotice: { log.append($0) })

        _ = try await service.sync()

        #expect(log.lines.isEmpty)
    }

    @Test func unreadableQueueRowIsLoggedAndDoesNotBlockTheRest() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        try VehicleLog.add(Vehicle.samples[0], in: container)
        let context = ModelContext(container)
        context.insert(
            PendingChangeEntity(
                changeID: UUID(), refKey: "futureEntity:\(UUID().uuidString)", sequence: 99, baseVersion: nil,
                modifiedAt: Date(), operationJSON: Data(#"{"op":"upsert","entity":"futureEntity","data":{}}"#.utf8)))
        try context.save()
        let log = LogBox()
        let store = SwiftDataSyncStore(
            modelContainer: container, onUnreadableChange: { refKey, _ in log.append(refKey) })

        let readable = try await store.pendingChanges()

        #expect(readable.count == 1)
        #expect(log.lines.count == 1)
        #expect(log.lines.first?.hasPrefix("futureEntity:") == true)
    }
}
