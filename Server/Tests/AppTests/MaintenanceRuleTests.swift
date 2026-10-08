import Foundation
import GarageAPI
import Testing

@testable import App

// Правила обслуживания: дочерняя сущность машины (docs/plans/stage-12-reminders.md, часть S).

@Test func ruleIsStoredAndPulledBack() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let rule = Fixture.rule(vehicleID: vehicle.id)
        _ = try await client.push(Fixture.upsert(vehicle))
        let version = try await client.push(Fixture.upsert(rule)).appliedVersion()
        #expect(version == 2)

        let pull = try await client.pull()
        #expect(pull.changes.map(\.version) == [1, 2])
        #expect(pull.changes[1].upsertedPayload == .maintenanceRule(rule))
        #expect(pull.skipped.isEmpty)
    }
}

@Test func ruleEditNeedsCurrentBaseVersionAndConflictsOtherwise() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let rule = Fixture.rule(vehicleID: vehicle.id)
        _ = try await client.push(Fixture.upsert(vehicle))
        let created = try await client.push(Fixture.upsert(rule)).appliedVersion()

        let edited = Fixture.rule(id: rule.id, vehicleID: vehicle.id, distanceKm: 15_000)
        let updated = try await client.push(Fixture.upsert(edited, base: created)).appliedVersion()
        #expect(updated == 3)

        let stale = Fixture.rule(id: rule.id, vehicleID: vehicle.id, distanceKm: 20_000)
        let conflict = try await client.push(Fixture.upsert(stale, base: created)).conflict()
        #expect(conflict.reason == .versionMismatch)
        #expect(conflict.current.version == updated)
        #expect(conflict.current.upsertedPayload == .maintenanceRule(edited))

        let duplicate = try await client.push(Fixture.upsert(rule)).conflict()
        #expect(duplicate.reason == .alreadyExists)
    }
}

@Test func ruleForMissingVehicleIsRejected() async throws {
    try await withTestApp { _, client in
        let missing = UUID()
        let error = try await client.push(Fixture.upsert(Fixture.rule(vehicleID: missing))).rejection()
        #expect(error.code == .vehicleNotFound)
        #expect(error.message == "Vehicle \(missing.uuidString) does not exist")
    }
}

@Test func ruleForDeletedVehicleIsRejected() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        _ = try await client.push(Fixture.upsert(vehicle))
        _ = try await client.push(Fixture.delete(.vehicle, vehicle.id))
        let error = try await client.push(Fixture.upsert(Fixture.rule(vehicleID: vehicle.id))).rejection()
        #expect(error.code == .vehicleNotFound)
    }
}

@Test func ruleContentIsValidatedWithDomainRules() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        _ = try await client.push(Fixture.upsert(vehicle))
        let id = vehicle.id
        let cases: [(MaintenanceRuleDTO, String)] = [
            (Fixture.rule(vehicleID: id, period: nil, distanceKm: nil), "noInterval"),
            (Fixture.rule(vehicleID: id, period: "months:0"), "periodOutOfRange"),
            (Fixture.rule(vehicleID: id, period: "months:121"), "periodOutOfRange"),
            (Fixture.rule(vehicleID: id, period: "days:3651"), "periodOutOfRange"),
            (Fixture.rule(vehicleID: id, period: "weeks:2"), "unknownPeriod"),
            (Fixture.rule(vehicleID: id, period: nil, distanceKm: 0), "distanceOutOfRange"),
            (Fixture.rule(vehicleID: id, period: nil, distanceKm: 10_000_001), "distanceOutOfRange"),
            (Fixture.rule(vehicleID: id, serviceType: "teleport"), "unknownServiceType"),
            (Fixture.rule(vehicleID: id, serviceType: "other:  "), "emptyServiceTypeDescription"),
            (Fixture.rule(vehicleID: id, startMileageKm: -1), "negativeMileage"),
        ]
        let results = try await client.push(cases.map { Fixture.upsert($0.0) })
        for (result, (_, expected)) in zip(results, cases) {
            let error = try result.rejection()
            #expect(error.code == .validationFailed)
            #expect(error.message.contains(expected), "\(error.message) should mention \(expected)")
        }
        // Положительный контроль: каждый из интервалов по отдельности и пользовательский тип проходят.
        let valid = [
            Fixture.rule(vehicleID: id, period: "months:120", distanceKm: nil),
            Fixture.rule(vehicleID: id, period: "days:1", distanceKm: nil),
            Fixture.rule(vehicleID: id, serviceType: "other:Antifreeze", period: nil, distanceKm: 1),
        ]
        for result in try await client.push(valid.map { Fixture.upsert($0) }) { _ = try result.appliedVersion() }
        // Отвергнутые правила не заняли версий: 1 — машина, дальше три принятых.
        #expect(try await client.pull().changes.map(\.version) == [1, 2, 3, 4])
    }
}

/// T9, часть сервера: период, который сервер отдал при pull, он же принимает обратно побайтно — клиент, не
/// понимающий период, возвращает строку без изменений (вторая часть — в GarageStorage, сырой период уходит в push).
/// Границы допустимого диапазона проверяются отдельно: расширение диапазона — изменение контракта (docs/api.md).
@Test(arguments: ["months:1", "months:12", "months:120", "days:1", "days:30", "days:3650"])
func periodServedByTheServerIsAcceptedBackByteForByte(period: String) async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let rule = Fixture.rule(vehicleID: vehicle.id, period: period)
        _ = try await client.push(Fixture.upsert(vehicle))
        let created = try await client.push(Fixture.upsert(rule)).appliedVersion()

        let served = try await client.pull().changes[1]
        guard case .maintenanceRule(let dto)? = served.upsertedPayload else {
            Issue.record("expected a rule upsert")
            return
        }
        #expect(dto.period == period)

        // Клиент меняет только пробег и возвращает период ровно таким, каким получил.
        var edited = dto
        edited.distanceKm = 12_000
        let updated = try await client.push(Fixture.upsert(edited, base: created)).appliedVersion()
        let again = try await client.pull(after: String(created)).changes
        #expect(again.map(\.version) == [updated])
        #expect(again.first?.upsertedPayload == .maintenanceRule(edited))
        guard case .maintenanceRule(let stored)? = again.first?.upsertedPayload else { return }
        #expect(stored.period == period)
    }
}

@Test func deletingRuleWritesTombstoneAndKeepsVehicle() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let rule = Fixture.rule(vehicleID: vehicle.id)
        _ = try await client.push(Fixture.upsert(vehicle))
        let created = try await client.push(Fixture.upsert(rule)).appliedVersion()
        #expect(try await client.push(Fixture.delete(.maintenanceRule, rule.id, base: created)).appliedVersion() == 3)

        let pull = try await client.pull(after: "2")
        #expect(pull.changes.map(\.operation) == [.delete(.maintenanceRule, id: rule.id)])
        let edit = try await client.push(Fixture.upsert(rule, base: created)).conflict()
        #expect(edit.reason == .deleted)
    }
}

/// Каскад по образцу удаления машины этапа 10 (`deletingVehicleCascadesTombstonesToItsRecords`):
/// правила машины получают tombstones вместе с записями, а правило другой машины остаётся живым.
@Test func deletingVehicleCascadesTombstonesToItsRulesAndRecords() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        let other = Fixture.vehicle()
        let rules = (0..<2).map { _ in Fixture.rule(vehicleID: vehicle.id) }
        let record = Fixture.record(vehicleID: vehicle.id)
        let keptRule = Fixture.rule(vehicleID: other.id)
        _ = try await client.push(
            [Fixture.upsert(vehicle), Fixture.upsert(other)] + rules.map { Fixture.upsert($0) } + [
                Fixture.upsert(record), Fixture.upsert(keptRule),
            ])
        // Versions 1…6 are taken.
        let deletion = Fixture.delete(.vehicle, vehicle.id, at: Fixture.date.addingTimeInterval(60))
        #expect(try await client.push(deletion).appliedVersion() == 7)

        let pull = try await client.pull(after: "6")
        #expect(pull.changes.map(\.version) == [7, 8, 9, 10])
        #expect(pull.changes[0].operation == .delete(.vehicle, id: vehicle.id))
        let cascaded = Set(pull.changes.dropFirst().map(\.operation))
        #expect(
            cascaded
                == Set(rules.map { .delete(.maintenanceRule, id: $0.id) } + [.delete(.serviceRecord, id: record.id)]))
        #expect(pull.changes.allSatisfy { $0.modifiedAt == Fixture.date.addingTimeInterval(60) })
        // Правило другой машины не затронуто.
        #expect(try await client.pull().changes.contains { $0.upsertedPayload == .maintenanceRule(keptRule) })

        // Новое правило к удалённой машине и upsert поверх каскадного tombstone.
        let orphan = try await client.push(Fixture.upsert(Fixture.rule(vehicleID: vehicle.id))).rejection()
        #expect(orphan.code == .vehicleNotFound)
        let resurrect = try await client.push(Fixture.upsert(rules[0], base: 3)).conflict()
        #expect(resurrect.reason == .deleted)
    }
}

@Test func cascadeCoversRulesTheDeletingDeviceNeverSaw() async throws {
    try await withTestApp { _, first in
        let second = try await first.registerAnotherDevice()
        let vehicle = Fixture.vehicle()
        let vehicleVersion = try await first.push(Fixture.upsert(vehicle)).appliedVersion()
        let rule = Fixture.rule(vehicleID: vehicle.id)
        let ruleVersion = try await second.push(Fixture.upsert(rule)).appliedVersion()
        #expect(ruleVersion == 2)

        let deletion = Fixture.delete(
            .vehicle, vehicle.id, base: vehicleVersion, at: Fixture.date.addingTimeInterval(60))
        #expect(try await first.push(deletion).appliedVersion() == 3)

        let pull = try await second.pull(after: "2")
        #expect(
            pull.changes.map(\.operation) == [
                .delete(.vehicle, id: vehicle.id), .delete(.maintenanceRule, id: rule.id),
            ])

        let edited = Fixture.rule(id: rule.id, vehicleID: vehicle.id, distanceKm: 15_000)
        let edit = try await second.push(Fixture.upsert(edited, base: ruleVersion)).conflict()
        #expect(edit.reason == .deleted)
        #expect(edit.current.version == 4)
    }
}

@Test func repeatedRulePushWithSameChangeIDReturnsSameVersion() async throws {
    try await withTestApp { _, client in
        let vehicle = Fixture.vehicle()
        _ = try await client.push(Fixture.upsert(vehicle))
        let change = Fixture.upsert(Fixture.rule(vehicleID: vehicle.id))
        let first = try await client.push(change).appliedVersion()
        let second = try await client.push(change).appliedVersion()
        #expect(first == second)
    }
}
