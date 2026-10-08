import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData
import Testing

@testable import GarageStorage

// Правила обслуживания и сырой вид машины в хранилище (docs/plans/stage-12-reminders.md, часть B1).

private func ruleRef(_ id: UUID) -> EntityRef { EntityRef(kind: .maintenanceRule, id: id) }
private func vehicleRef(_ id: UUID) -> EntityRef { EntityRef(kind: .vehicle, id: id) }

private let ruleDate = Date(timeIntervalSince1970: 1_700_000_000)

private func makeTestRule(
    id: UUID = UUID(), vehicleID: UUID, serviceType: ServiceType = .oilChange, period: ServicePeriod? = .months(12),
    distanceKm: Int? = 10_000
) throws -> MaintenanceRule {
    try MaintenanceRule(
        id: id, vehicleID: vehicleID, serviceType: serviceType, period: period, distanceKm: distanceKm,
        start: MaintenanceStart(date: ruleDate, mileageKm: 87_000))
}

private func storedRules(in container: ModelContainer) throws -> [MaintenanceRuleEntity] {
    try ModelContext(container).fetch(FetchDescriptor<MaintenanceRuleEntity>())
}

private func storedRule(_ id: UUID, in container: ModelContainer) throws -> MaintenanceRuleEntity? {
    try storedRules(in: container).first { $0.id == id }
}

private func storedVehicle(_ id: UUID, in container: ModelContainer) throws -> VehicleEntity? {
    try ModelContext(container).fetch(FetchDescriptor<VehicleEntity>()).first { $0.id == id }
}

private func pendingJSON(_ ref: EntityRef, in container: ModelContainer) throws -> String? {
    try SyncState.pendingEntity(for: ref, in: ModelContext(container)).map {
        String(decoding: $0.operationJSON, as: UTF8.self)
    }
}

private func clearQueue(_ container: ModelContainer) throws {
    let context = ModelContext(container)
    for pending in try context.fetch(FetchDescriptor<PendingChangeEntity>()) { context.delete(pending) }
    try context.save()
}

private func containerWithVehicle(_ vehicle: Vehicle = Vehicle.samples[0]) throws -> ModelContainer {
    let container = try GarageStore.makeContainer(inMemory: true)
    try VehicleLog.add(vehicle, in: container)
    try clearQueue(container)
    return container
}

private struct Boom: Error {}

@Suite struct RuleLogTests {
    @Test func addStoresRuleAndQueuesUpsertInOneSave() throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let rule = try makeTestRule(vehicleID: vehicle.id, serviceType: .other("Антифриз"))

        try RuleLog.add(rule, in: container)

        let entity = try #require(try storedRule(rule.id, in: container))
        #expect(try entity.toDomain() == rule)
        #expect(entity.vehicle?.id == vehicle.id)
        let pending = try SyncQueue.pendingChange(
            #require(try SyncState.pendingEntity(for: ruleRef(rule.id), in: ModelContext(container))))
        #expect(pending.operation == .upsert(.maintenanceRule(rule, RuleSyncExtras())))
        #expect(pending.baseVersion == nil)
    }

    @Test func addToMissingVehicleThrowsAndStoresNothing() throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let rule = try makeTestRule(vehicleID: UUID())

        #expect(throws: ServiceLogError.vehicleNotFound(rule.vehicleID)) { try RuleLog.add(rule, in: container) }
        #expect(try storedRules(in: container).isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PendingChangeEntity>()) == 0)
    }

    @Test func failedSaveLeavesNoRuleAndNoQueueEntry() throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let rule = try makeTestRule(vehicleID: vehicle.id)

        #expect(throws: Boom.self) { try RuleLog.add(rule, in: container) { _ in throw Boom() } }

        #expect(try storedRules(in: container).isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PendingChangeEntity>()) == 0)
    }

    @Test func updateChangesFieldsAndRepeatedEditsCollapseIntoOneQueueEntry() throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let rule = try makeTestRule(vehicleID: vehicle.id)
        try RuleLog.add(rule, in: container)
        var first = rule
        try first.updateInterval(period: .months(6), distanceKm: 5_000)
        var second = first
        try second.updateInterval(period: .days(90), distanceKm: nil)

        try RuleLog.update(first, period: .set, in: container)
        try RuleLog.update(second, period: .set, in: container)

        #expect(try storedRule(rule.id, in: container)?.toDomain() == second)
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<PendingChangeEntity>()) == 1)
        let pending = try SyncQueue.pendingChange(
            #require(try SyncState.pendingEntity(for: ruleRef(rule.id), in: context)))
        #expect(pending.operation == .upsert(.maintenanceRule(second, RuleSyncExtras())))
    }

    @Test func updateOfMissingRuleThrows() throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let rule = try makeTestRule(vehicleID: vehicle.id)

        #expect(throws: ServiceLogError.ruleNotFound(rule.id)) {
            try RuleLog.update(rule, period: .set, in: container)
        }
    }

    @Test func deleteRemovesRuleAndAlwaysQueuesDelete() throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let rule = try makeTestRule(vehicleID: vehicle.id)
        try RuleLog.add(rule, in: container)

        try RuleLog.delete(id: rule.id, in: container)

        #expect(try storedRules(in: container).isEmpty)
        let context = ModelContext(container)
        let pending = try SyncQueue.pendingChange(
            #require(try SyncState.pendingEntity(for: ruleRef(rule.id), in: context)))
        #expect(pending.operation == .delete(ruleRef(rule.id)))
        // Правила нет — не ошибка и не новая запись в очереди.
        try RuleLog.delete(id: UUID(), in: container)
        #expect(try context.fetchCount(FetchDescriptor<PendingChangeEntity>()) == 1)
    }

    @Test func adapterTranslatesErrorsToDomainOnes() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let adapter = SwiftDataMaintenanceRuleRepository(container: container)
        let rule = try makeTestRule(vehicleID: UUID())

        await #expect(throws: RepositoryError.vehicleNotFound(rule.vehicleID)) { try await adapter.add(rule) }
        await #expect(throws: RepositoryError.ruleNotFound(rule.id)) {
            try await adapter.update(rule, period: .set)
        }
        try await adapter.delete(id: rule.id)
    }
}

@Suite struct RuleCascadeTests {
    @Test func localVehicleDeletionRemovesItsRulesAndTheirPendingUpserts() throws {
        let vehicle = Vehicle.samples[0]
        let other = Vehicle.samples[1]
        let container = try containerWithVehicle(vehicle)
        try VehicleLog.add(other, in: container)
        let rule = try makeTestRule(vehicleID: vehicle.id)
        let kept = try makeTestRule(vehicleID: other.id)
        try RuleLog.add(rule, in: container)
        try RuleLog.add(kept, in: container)

        try VehicleLog.delete(id: vehicle.id, in: container)

        #expect(try storedRules(in: container).map(\.id) == [kept.id])
        let context = ModelContext(container)
        #expect(try SyncState.pendingEntity(for: ruleRef(rule.id), in: context) == nil)
        #expect(try SyncState.pendingEntity(for: ruleRef(kept.id), in: context) != nil)
        #expect(try SyncState.pendingEntity(for: vehicleRef(vehicle.id), in: context) != nil)
    }

    @Test func serverVehicleDeletionRemovesItsRulesAndTheirPendingUpserts() async throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let rule = try makeTestRule(vehicleID: vehicle.id)
        try RuleLog.add(rule, in: container)
        let store = SwiftDataSyncStore(modelContainer: container)

        try await store.apply(
            RemoteChange(version: 9, operation: .delete(vehicleRef(vehicle.id))), for: vehicleRef(vehicle.id))

        #expect(try storedRules(in: container).isEmpty)
        #expect(try storedVehicle(vehicle.id, in: container) == nil)
        #expect(try SyncState.pendingEntity(for: ruleRef(rule.id), in: ModelContext(container)) == nil)
    }

    @Test func snapshotContainsOnlyValidEntities() async throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let good = try makeTestRule(vehicleID: vehicle.id)
        try RuleLog.add(good, in: container)
        let context = ModelContext(container)
        let bad = MaintenanceRuleEntity(
            id: UUID(), vehicle: nil, serviceTypeRaw: "teleport", periodRaw: "months:1", distanceKm: nil,
            startDate: ruleDate, startMileageKm: 1)
        context.insert(bad)
        try context.save()

        let snapshot = try await SwiftDataMaintenanceRuleRepository(container: container).snapshot()

        #expect(snapshot.rules == [good])
        #expect(snapshot.vehicles.map(\.id) == [vehicle.id])
    }
}

@Suite struct RuleSyncTests {
    @Test func serverRuleIsAppliedAndRejectedWithoutItsVehicle() async throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let store = SwiftDataSyncStore(modelContainer: container)
        let rule = try makeTestRule(vehicleID: vehicle.id)
        let orphan = try makeTestRule(vehicleID: UUID())

        try await store.apply(
            RemoteChange(version: 3, operation: .upsert(.maintenanceRule(rule, RuleSyncExtras()))),
            for: ruleRef(rule.id))
        #expect(try storedRule(rule.id, in: container)?.toDomain() == rule)
        #expect(try await store.version(of: ruleRef(rule.id)) == 3)

        await #expect(throws: SyncStoreError.self) {
            try await store.apply(
                RemoteChange(version: 4, operation: .upsert(.maintenanceRule(orphan, RuleSyncExtras()))),
                for: ruleRef(orphan.id))
        }
        #expect(try storedRule(orphan.id, in: container) == nil)

        try await store.apply(RemoteChange(version: 5, operation: .delete(ruleRef(rule.id))), for: ruleRef(rule.id))
        #expect(try storedRules(in: container).isEmpty)
    }

    // T9: сырой период живёт, пока интервал по времени не тронут явно (открытый вопрос S, решение пользователя).

    @Test func rawPeriodSurvivesKeepUnrecognizedEditsAndGoesToPushByteForByte() async throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let store = SwiftDataSyncStore(modelContainer: container)
        let rule = try makeTestRule(vehicleID: vehicle.id, period: nil, distanceKm: 10_000)
        try await store.apply(
            RemoteChange(
                version: 3, operation: .upsert(.maintenanceRule(rule, RuleSyncExtras(rawPeriod: "weeks:2")))),
            for: ruleRef(rule.id))
        #expect(try storedRule(rule.id, in: container)?.rawPeriod == "weeks:2")
        var edited = rule
        try edited.updateInterval(period: nil, distanceKm: 15_000)

        try RuleLog.update(edited, period: .keepUnrecognized, in: container)

        #expect(try storedRule(rule.id, in: container)?.rawPeriod == "weeks:2")
        let json = try #require(try pendingJSON(ruleRef(rule.id), in: container))
        #expect(json.contains(#""period":"weeks:2""#))
        let change = try #require(await store.pendingChange(for: ruleRef(rule.id)))
        guard case .upsert(.maintenanceRule(let sent)) = change.operation.changeOperation else {
            Issue.record("expected a rule upsert")
            return
        }
        #expect(sent.period == "weeks:2")
        #expect(sent.distanceKm == 15_000)
    }

    /// Положительный контроль: явное действие с полем (`set`) сбрасывает сырой период, на сервер уходит известный.
    @Test func setClearsTheRawPeriodAndSendsTheKnownOne() async throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let store = SwiftDataSyncStore(modelContainer: container)
        let rule = try makeTestRule(vehicleID: vehicle.id, period: nil, distanceKm: 10_000)
        try await store.apply(
            RemoteChange(
                version: 3, operation: .upsert(.maintenanceRule(rule, RuleSyncExtras(rawPeriod: "weeks:2")))),
            for: ruleRef(rule.id))
        var edited = rule
        try edited.updateInterval(period: .months(6), distanceKm: 10_000)

        try RuleLog.update(edited, period: .set, in: container)

        #expect(try storedRule(rule.id, in: container)?.rawPeriod == nil)
        let json = try #require(try pendingJSON(ruleRef(rule.id), in: container))
        #expect(json.contains(#""period":"months:6""#))
        #expect(!json.contains("weeks"))
    }

    @Test func settingNoPeriodAtAllAlsoClearsTheRawOne() throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let rule = try makeTestRule(vehicleID: vehicle.id, period: nil, distanceKm: 10_000)
        try RuleLog.add(rule, in: container)
        let context = ModelContext(container)
        try #require(try context.fetch(FetchDescriptor<MaintenanceRuleEntity>()).first).rawPeriod = "weeks:2"
        try context.save()

        try RuleLog.update(rule, period: .set, in: container)

        #expect(try storedRule(rule.id, in: container)?.rawPeriod == nil)
        #expect(!(try #require(try pendingJSON(ruleRef(rule.id), in: container))).contains("period"))
    }

    /// Адаптеры пробрасывают намерение пользователя до хранилища: с `.set` вместо проброса сырое значение пропало бы тихо.
    @Test func ruleAdapterForwardsTheKeepUnrecognizedIntent() async throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let store = SwiftDataSyncStore(modelContainer: container)
        let rule = try makeTestRule(vehicleID: vehicle.id, period: nil, distanceKm: 10_000)
        try await store.apply(
            RemoteChange(
                version: 3, operation: .upsert(.maintenanceRule(rule, RuleSyncExtras(rawPeriod: "weeks:2")))),
            for: ruleRef(rule.id))
        let adapter = SwiftDataMaintenanceRuleRepository(container: container)

        try await adapter.update(rule, period: .keepUnrecognized)
        #expect(try storedRule(rule.id, in: container)?.rawPeriod == "weeks:2")
        #expect(try #require(try pendingJSON(ruleRef(rule.id), in: container)).contains(#""period":"weeks:2""#))

        try await adapter.update(rule, period: .set)
        #expect(try storedRule(rule.id, in: container)?.rawPeriod == nil)
    }

    @Test func vehicleAdapterForwardsTheKeepUnrecognizedIntent() async throws {
        let container = try GarageStore.makeContainer(inMemory: true)
        let store = SwiftDataSyncStore(modelContainer: container)
        let vehicle = Vehicle.samples[0]
        try await store.apply(
            RemoteChange(version: 2, operation: .upsert(.vehicle(vehicle, VehicleSyncExtras(rawKind: "tractor")))),
            for: vehicleRef(vehicle.id))
        let adapter = SwiftDataVehicleRepository(container: container)

        try await adapter.update(vehicle, kind: .keepUnrecognized)
        #expect(try storedVehicle(vehicle.id, in: container)?.rawKind == "tractor")
        #expect(try #require(try pendingJSON(vehicleRef(vehicle.id), in: container)).contains(#""kind":"tractor""#))

        try await adapter.update(vehicle, kind: .set)
        #expect(try storedVehicle(vehicle.id, in: container)?.rawKind == nil)
    }

    @Test func changingAnUnknownServerTypeDropsItsRawString() async throws {
        let vehicle = Vehicle.samples[0]
        let container = try containerWithVehicle(vehicle)
        let store = SwiftDataSyncStore(modelContainer: container)
        let rule = try makeTestRule(vehicleID: vehicle.id, serviceType: .other("coolant"))
        try await store.apply(
            RemoteChange(
                version: 3, operation: .upsert(.maintenanceRule(rule, RuleSyncExtras(rawServiceType: "coolant")))),
            for: ruleRef(rule.id))
        var edited = rule
        try edited.updateServiceType(.brakes)

        try RuleLog.update(edited, period: .keepUnrecognized, in: container)

        #expect(try storedRule(rule.id, in: container)?.rawServiceType == nil)
        #expect(try #require(try pendingJSON(ruleRef(rule.id), in: container)).contains(#""serviceType":"brakes""#))
    }
}

@Suite struct VehicleRawKindTests {
    private func appliedUnknownKind() async throws -> (ModelContainer, SwiftDataSyncStore, Vehicle) {
        let container = try GarageStore.makeContainer(inMemory: true)
        let store = SwiftDataSyncStore(modelContainer: container)
        let vehicle = Vehicle.samples[0]
        try await store.apply(
            RemoteChange(version: 2, operation: .upsert(.vehicle(vehicle, VehicleSyncExtras(rawKind: "tractor")))),
            for: vehicleRef(vehicle.id))
        return (container, store, vehicle)
    }

    @Test func unknownKindIsStoredAsCarWithTheRawValueNextToIt() async throws {
        let (container, _, vehicle) = try await appliedUnknownKind()

        let entity = try #require(try storedVehicle(vehicle.id, in: container))
        #expect(entity.rawKind == "tractor")
        #expect(entity.kindRaw == "car")
        #expect(try entity.toDomain() == vehicle)
        #expect(try entity.listItem().rawKind == "tractor")
    }

    @Test func keepUnrecognizedEditKeepsRawKindAndPushCarriesIt() async throws {
        let (container, _, vehicle) = try await appliedUnknownKind()
        let edited = try Vehicle(
            id: vehicle.id, kind: .car, make: "Lexus", model: vehicle.model, year: vehicle.year,
            mileageKm: vehicle.mileageKm)

        try VehicleLog.update(edited, kind: .keepUnrecognized, in: container)

        #expect(try storedVehicle(vehicle.id, in: container)?.rawKind == "tractor")
        let json = try #require(try pendingJSON(vehicleRef(vehicle.id), in: container))
        #expect(json.contains(#""kind":"tractor""#))
        #expect(json.contains(#""make":"Lexus""#))
    }

    /// Положительный контроль: `set(.car)` сбрасывает сырое значение, хотя домен и так был `.car`.
    @Test func setResetsRawKindAndPushCarriesTheChosenOne() async throws {
        let (container, _, vehicle) = try await appliedUnknownKind()

        try VehicleLog.update(vehicle, kind: .set, in: container)

        #expect(try storedVehicle(vehicle.id, in: container)?.rawKind == nil)
        let json = try #require(try pendingJSON(vehicleRef(vehicle.id), in: container))
        #expect(json.contains(#""kind":"car""#))
    }

    @Test func pullAppliesAVehicleOfUnknownKindWithItsRecords() async throws {
        let server = FakeSyncServer()
        let first = try GarageStore.makeContainer(inMemory: true)
        let second = try GarageStore.makeContainer(inMemory: true)
        let vehicle = Vehicle.samples[0]
        let firstStore = SwiftDataSyncStore(modelContainer: first)
        let secondStore = SwiftDataSyncStore(modelContainer: second)
        // Вид «tractor» кладёт на сервер «чужой» клиент: машина с сырым видом уходит push'ем как есть.
        try await firstStore.apply(
            RemoteChange(version: nil, operation: .upsert(.vehicle(vehicle, VehicleSyncExtras(rawKind: "tractor")))),
            for: vehicleRef(vehicle.id))
        try VehicleLog.update(vehicle, kind: .keepUnrecognized, in: first)
        let record = try makeSyncRecord(for: vehicle)
        try ServiceLog.add(record, toVehicleWithID: vehicle.id, in: first)
        try SyncSupport.prepare(first)
        try SyncSupport.prepare(second)

        _ = try await SyncEngine(
            store: firstStore, client: SyncAPIClient(transport: server, token: "t"), receipts: firstStore
        ).sync()
        let report = try await SyncEngine(
            store: secondStore, client: SyncAPIClient(transport: server, token: "t"), receipts: secondStore
        ).sync()

        #expect(report.skipped.isEmpty)
        #expect(try storedVehicle(vehicle.id, in: second)?.rawKind == "tractor")
        #expect(try ModelContext(second).fetchCount(FetchDescriptor<ServiceRecordEntity>()) == 1)
    }
}
