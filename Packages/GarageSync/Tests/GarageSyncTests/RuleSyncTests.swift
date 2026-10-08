import Foundation
import GarageAPI
import GarageCore
import Testing

@testable import GarageSync

private let vehicleRef = ref(.vehicle, IDs.vehicle)
private let ruleRef = ref(.maintenanceRule, IDs.rule)

private func ruleChange(_ version: Int64, _ modifiedAt: String, _ rule: MaintenanceRule) -> ServerChange {
    ServerChange(
        version: version, modifiedAt: date(modifiedAt),
        operation: .upsert(SyncEntity.maintenanceRule(rule, RuleSyncExtras()).payload))
}

private func applied(_ id: UUID, version: Int64) -> PushResult {
    PushResult(changeID: id, outcome: .applied(version: version))
}

@Suite struct RuleMappingTests {
    @Test func goldenRoundTrips() throws {
        let data = try GoldenExamples.data("maintenance-rule")
        let dto = try APICoding.makeDecoder().decode(MaintenanceRuleDTO.self, from: data)
        let (rule, extras) = try MaintenanceRule.decoded(from: dto)
        #expect(rule.serviceType == .oilChange)
        #expect(rule.period == .months(12))
        #expect(rule.distanceKm == 10_000)
        #expect(rule.start.mileageKm == 87_400)
        #expect(extras == RuleSyncExtras())
        #expect(MaintenanceRuleDTO(rule, extras: extras) == dto)
        let encoded = try APICoding.makeEncoder().encode(MaintenanceRuleDTO(rule, extras: extras))
        #expect(try JSONValue(data: encoded) == JSONValue(data: data))
    }

    /// T9: golden `maintenance-rule-unknown-period` (`"weeks:2"`, интервала по пробегу нет) — известных интервалов не
    /// остаётся, правило не отображается в домен.
    @Test func goldenUnknownPeriodWithoutDistanceCannotBeMapped() throws {
        let dto = try APICoding.makeDecoder().decode(
            MaintenanceRuleDTO.self, from: GoldenExamples.data("maintenance-rule-unknown-period"))
        #expect(throws: ValidationError.noInterval) { try MaintenanceRule.decoded(from: dto) }
    }

    @Test func unknownPeriodIsKeptRawAndSentBackWhileDistanceRemains() throws {
        var dto = try APICoding.makeDecoder().decode(
            MaintenanceRuleDTO.self, from: GoldenExamples.data("maintenance-rule-unknown-period"))
        dto.distanceKm = 10_000
        let (rule, extras) = try MaintenanceRule.decoded(from: dto)
        #expect(rule.period == nil)
        #expect(rule.distanceKm == 10_000)
        #expect(extras.rawPeriod == "weeks:2")
        #expect(MaintenanceRuleDTO(rule, extras: extras) == dto)
    }

    @Test func userChosenPeriodReplacesTheRawOne() throws {
        let dto = MaintenanceRuleDTO(
            id: IDs.rule, vehicleID: IDs.vehicle, serviceType: "oilChange", period: "weeks:2", distanceKm: 10_000,
            startDate: date("2026-10-08T00:00:00.000Z"), startMileageKm: 87_400)
        var (rule, extras) = try MaintenanceRule.decoded(from: dto)
        try rule.updateInterval(period: .months(6), distanceKm: 10_000)
        #expect(MaintenanceRuleDTO(rule, extras: extras).period == "months:6")
        extras.rawPeriod = nil
        #expect(MaintenanceRuleDTO(rule, extras: extras).period == "months:6")
    }

    /// Известный формат с выходом за границы — нарушение формата, а не эволюция: правило пропускается, сырым не хранится.
    /// Положительный контроль: неканоничная запись (`"days:+5"`) — незнакомый период, хранится сырым.
    @Test func periodOutOfRangeFailsWhileNonCanonicalStaysRaw() throws {
        var dto = MaintenanceRuleDTO(
            id: IDs.rule, vehicleID: IDs.vehicle, serviceType: "oilChange", period: "months:999", distanceKm: 5_000,
            startDate: date("2026-10-08T00:00:00.000Z"), startMileageKm: 0)
        #expect(throws: ValidationError.periodOutOfRange(999)) { try MaintenanceRule.decoded(from: dto) }
        dto.period = "days:+5"
        #expect(try MaintenanceRule.decoded(from: dto).extras.rawPeriod == "days:+5")
    }

    @Test func unknownServiceTypeIsKeptAndSentBack() throws {
        var dto = MaintenanceRuleDTO(makeRule(), extras: RuleSyncExtras())
        dto.serviceType = "coolant"
        let (rule, extras) = try MaintenanceRule.decoded(from: dto)
        #expect(rule.serviceType == .other("coolant"))
        #expect(extras.rawServiceType == "coolant")
        #expect(MaintenanceRuleDTO(rule, extras: extras).serviceType == "coolant")
    }

    @Test func userChosenTypeIsEncodedFromTheDomain() {
        let extras = RuleSyncExtras(rawServiceType: "coolant")
        #expect(MaintenanceRuleDTO(makeRule(serviceType: .brakes), extras: extras).serviceType == "brakes")
        #expect(
            MaintenanceRuleDTO(makeRule(serviceType: .other("coolant")), extras: RuleSyncExtras()).serviceType
                == "other:coolant")
    }

    @Test func invalidContentThrowsValidationError() {
        var dto = MaintenanceRuleDTO(makeRule(), extras: RuleSyncExtras())
        dto.distanceKm = 0
        #expect(throws: ValidationError.distanceOutOfRange(0)) { try MaintenanceRule.decoded(from: dto) }
        dto.distanceKm = 10_000
        dto.startMileageKm = -1
        #expect(throws: ValidationError.negativeMileage(-1)) { try MaintenanceRule.decoded(from: dto) }
    }
}

@Suite struct RuleSyncEngineTests {
    @Test func pushAndPullOfARule() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T09:00:00.000Z"), changeID: IDs.changeA)
        await store.upsertLocal(
            .maintenanceRule(makeRule(), RuleSyncExtras()), modifiedAt: date("2026-10-07T09:01:00.000Z"),
            changeID: IDs.changeB)
        let transport = FakeHTTPTransport([
            try .json(PushResponse(results: [applied(IDs.changeA, version: 1), applied(IDs.changeB, version: 2)])),
            try .json(emptyPull(cursor: "2")),
        ])
        let report = try await makeEngine(store, transport).sync()

        let pushed = try decodePush(await transport.requests[0])
        #expect(pushed.changes.map(\.operation.ref) == [vehicleRef, ruleRef])
        #expect(report.pushed == 2)
        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.version(of: ruleRef) == 2)
    }

    @Test func newDevicePullsARule() async throws {
        let store = InMemorySyncStore()
        let pull = PullResponse(
            changes: [
                ServerChange(
                    version: 1, modifiedAt: date("2026-10-07T09:00:00.000Z"),
                    operation: .upsert(SyncEntity.vehicle(makeVehicle()).payload)),
                ruleChange(2, "2026-10-07T09:01:00.000Z", makeRule()),
            ], cursor: "2", hasMore: false)
        _ = try await makeEngine(store, FakeHTTPTransport([try .json(pull)])).sync()

        #expect(await store.storedRule(IDs.rule)?.rule == makeRule())
        #expect(await store.version(of: ruleRef) == 2)
    }

    /// LWW как у записи: локальная правка новее — остаётся в очереди поверх версии сервера.
    @Test func newerLocalRuleEditWinsAndIsRebased() async throws {
        let store = InMemorySyncStore()
        await store.storeSynced(.vehicle(makeVehicle()), version: 1)
        await store.storeSynced(.maintenanceRule(makeRule(), RuleSyncExtras()), version: 2)
        await store.upsertLocal(
            .maintenanceRule(makeRule(distanceKm: 15_000), RuleSyncExtras()),
            modifiedAt: date("2026-10-07T12:00:00.000Z"), changeID: IDs.changeA)
        let current = ruleChange(3, "2026-10-07T11:00:00.000Z", makeRule(distanceKm: 5_000))
        let transport = FakeHTTPTransport([
            try .json(
                PushResponse(results: [
                    PushResult(changeID: IDs.changeA, outcome: .conflict(reason: .versionMismatch, current: current))
                ])),
            try .json(PushResponse(results: [applied(IDs.changeA, version: 4)])),
            try .json(emptyPull(cursor: "4")),
        ])
        _ = try await makeEngine(store, transport).sync()

        let resent = try decodePush(await transport.requests[1])
        #expect(resent.changes.map(\.baseVersion) == [3])
        #expect(await store.storedRule(IDs.rule)?.rule.distanceKm == 15_000)
        #expect(await store.version(of: ruleRef) == 4)
    }

    @Test func newerServerRuleWinsOverOlderLocalEdit() async throws {
        let store = InMemorySyncStore()
        await store.storeSynced(.vehicle(makeVehicle()), version: 1)
        await store.storeSynced(.maintenanceRule(makeRule(), RuleSyncExtras()), version: 2)
        await store.upsertLocal(
            .maintenanceRule(makeRule(distanceKm: 15_000), RuleSyncExtras()),
            modifiedAt: date("2026-10-07T10:00:00.000Z"), changeID: IDs.changeA)
        let current = ruleChange(3, "2026-10-07T11:00:00.000Z", makeRule(distanceKm: 5_000))
        let transport = FakeHTTPTransport([
            try .json(
                PushResponse(results: [
                    PushResult(changeID: IDs.changeA, outcome: .conflict(reason: .versionMismatch, current: current))
                ])),
            try .json(emptyPull(cursor: "3")),
        ])
        _ = try await makeEngine(store, transport).sync()

        #expect(await store.storedRule(IDs.rule)?.rule.distanceKm == 5_000)
        #expect(await store.pendingChanges().isEmpty)
    }

    /// Аналог `unknownServiceTypeSurvivesLocalEdit`: правило с незнакомым периодом и типом правят локально (меняют
    /// пробег), push несёт сырые строки без изменений.
    @Test func unknownPeriodAndTypeSurviveLocalEdit() async throws {
        let dto = MaintenanceRuleDTO(
            id: IDs.rule, vehicleID: IDs.vehicle, serviceType: "coolant", period: "weeks:2", distanceKm: 10_000,
            startDate: date("2026-10-08T00:00:00.000Z"), startMileageKm: 87_400)
        let store = InMemorySyncStore()
        let pull = PullResponse(
            changes: [
                ServerChange(
                    version: 1, modifiedAt: date("2026-10-07T09:00:00.000Z"),
                    operation: .upsert(SyncEntity.vehicle(makeVehicle()).payload)),
                ServerChange(
                    version: 2, modifiedAt: date("2026-10-07T09:01:00.000Z"), operation: .upsert(.maintenanceRule(dto))),
            ], cursor: "2", hasMore: false)
        let transport = FakeHTTPTransport([try .json(pull)])
        let engine = makeEngine(store, transport)
        _ = try await engine.sync()

        let stored = try #require(await store.storedRule(IDs.rule))
        #expect(stored.extras == RuleSyncExtras(rawServiceType: "coolant", rawPeriod: "weeks:2"))

        var edited = stored.rule
        try edited.updateInterval(period: nil, distanceKm: 15_000)
        await store.upsertLocal(
            .maintenanceRule(edited, stored.extras), modifiedAt: date("2026-10-07T12:00:00.000Z"),
            changeID: IDs.changeA)
        await transport.enqueue(try .json(PushResponse(results: [applied(IDs.changeA, version: 3)])))
        await transport.enqueue(try .json(emptyPull(cursor: "3")))
        _ = try await engine.sync()

        let pushed = try decodePush(await transport.requests[1])
        guard case .upsert(.maintenanceRule(let sent)) = pushed.changes[0].operation else {
            Issue.record("expected a rule upsert")
            return
        }
        #expect(sent.serviceType == "coolant")
        #expect(sent.period == "weeks:2")
        #expect(sent.distanceKm == 15_000)
    }

    @Test func vehicleNotFoundDeletesRuleLocally() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .maintenanceRule(makeRule(), RuleSyncExtras()), modifiedAt: date("2026-10-07T11:00:00.000Z"),
            changeID: IDs.changeA)
        let error = APIError(code: .vehicleNotFound, message: "no vehicle")
        let transport = FakeHTTPTransport([
            try .json(PushResponse(results: [PushResult(changeID: IDs.changeA, outcome: .rejected(error))])),
            try .json(emptyPull(cursor: "1")),
        ])
        let report = try await makeEngine(store, transport).sync()

        #expect(await store.storedRule(IDs.rule) == nil)
        #expect(await store.pendingChanges().isEmpty)
        #expect(report.rejected.count == 1)
    }

    /// Положительный контроль к предыдущему: правило машины, отвергнутой по валидации, локально не удаляется.
    @Test func ruleOfRejectedVehicleIsNotDeleted() async throws {
        let store = InMemorySyncStore()
        await store.upsertLocal(
            .vehicle(makeVehicle()), modifiedAt: date("2026-10-07T09:00:00.000Z"), changeID: IDs.changeA)
        await store.upsertLocal(
            .maintenanceRule(makeRule(), RuleSyncExtras()), modifiedAt: date("2026-10-07T09:01:00.000Z"),
            changeID: IDs.changeB)
        let transport = FakeHTTPTransport([
            try .json(
                PushResponse(results: [
                    PushResult(
                        changeID: IDs.changeA, outcome: .rejected(APIError(code: .validationFailed, message: "bad"))),
                    PushResult(
                        changeID: IDs.changeB, outcome: .rejected(APIError(code: .vehicleNotFound, message: "none"))),
                ])),
            try .json(emptyPull(cursor: "1")),
        ])
        _ = try await makeEngine(store, transport).sync()
        #expect(await store.storedRule(IDs.rule) != nil)
        #expect(await store.pendingChanges().isEmpty)
    }

    @Test func deletedConflictRemovesLocalRule() async throws {
        let store = InMemorySyncStore()
        await store.storeSynced(.vehicle(makeVehicle()), version: 1)
        await store.storeSynced(.maintenanceRule(makeRule(), RuleSyncExtras()), version: 2)
        await store.upsertLocal(
            .maintenanceRule(makeRule(distanceKm: 15_000), RuleSyncExtras()),
            modifiedAt: date("2026-10-07T12:00:00.000Z"), changeID: IDs.changeA)
        let tombstone = ServerChange(
            version: 5, modifiedAt: date("2026-10-07T11:00:00.000Z"),
            operation: .delete(.maintenanceRule, id: IDs.rule))
        let transport = FakeHTTPTransport([
            try .json(
                PushResponse(results: [
                    PushResult(changeID: IDs.changeA, outcome: .conflict(reason: .deleted, current: tombstone))
                ])),
            try .json(emptyPull(cursor: "5")),
        ])
        _ = try await makeEngine(store, transport).sync()

        #expect(await store.storedRule(IDs.rule) == nil)
        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.version(of: ruleRef) == 5)
    }

    /// Контракт `SyncStore.apply`: удаление машины с сервера удаляет её правила и pending-upsert'ы правил;
    /// правило другой машины живо (положительный контроль).
    @Test func remoteVehicleDeleteDropsRulesAndTheirPendingUpserts() async throws {
        let otherVehicle = uuid("44444444-4444-4444-8444-444444444441")
        let store = InMemorySyncStore()
        await store.storeSynced(.vehicle(makeVehicle()), version: 1)
        await store.storeSynced(.vehicle(makeVehicle(id: otherVehicle, make: "Honda")), version: 2)
        await store.storeSynced(.maintenanceRule(makeRule(), RuleSyncExtras()), version: 3)
        await store.storeSynced(
            .maintenanceRule(makeRule(id: IDs.otherRule, vehicleID: otherVehicle), RuleSyncExtras()), version: 4)
        let pull = PullResponse(
            changes: [
                ServerChange(
                    version: 6, modifiedAt: date("2026-10-07T11:00:00.000Z"),
                    operation: .delete(.vehicle, id: IDs.vehicle))
            ], cursor: "6", hasMore: false)
        let transport = FakeHTTPTransport([
            .before(
                {
                    // Правка правила, сделанная, пока sync уже прошёл push.
                    await store.upsertLocal(
                        .maintenanceRule(makeRule(distanceKm: 15_000), RuleSyncExtras()),
                        modifiedAt: date("2026-10-07T12:00:00.000Z"), changeID: IDs.changeA)
                }, try .json(pull))
        ])
        _ = try await makeEngine(store, transport).sync()

        #expect(await store.vehicle(IDs.vehicle) == nil)
        #expect(await store.storedRule(IDs.rule) == nil)
        #expect(await store.pendingChanges().isEmpty)
        #expect(await store.storedRule(IDs.otherRule) != nil)
    }

    @Test func unmappablePulledRuleIsSkippedNotFatal() async throws {
        let store = InMemorySyncStore()
        let bad = MaintenanceRuleDTO(
            id: IDs.rule, vehicleID: IDs.vehicle, serviceType: "oilChange", period: "weeks:2",
            startDate: date("2026-10-08T00:00:00.000Z"), startMileageKm: 87_400)
        let pull = PullResponse(
            changes: [
                ServerChange(
                    version: 2, modifiedAt: date("2026-10-07T09:01:00.000Z"), operation: .upsert(.maintenanceRule(bad))),
                ServerChange(
                    version: 3, modifiedAt: date("2026-10-07T09:02:00.000Z"),
                    operation: .upsert(SyncEntity.vehicle(makeVehicle()).payload)),
            ], cursor: "3", hasMore: false)
        let report = try await makeEngine(store, FakeHTTPTransport([try .json(pull)])).sync()

        #expect(report.skipped.map { $0.ref } == [ruleRef])
        #expect(report.pulled == 1)
        #expect(await store.storedRule(IDs.rule) == nil)
        #expect(await store.vehicle(IDs.vehicle) != nil)
        #expect(await store.cursor() == "3")
    }
}
