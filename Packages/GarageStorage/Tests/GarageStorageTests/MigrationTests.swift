import Foundation
import GarageAPI
import GarageCore
import GarageSync
import SwiftData
import Testing

@testable import GarageStorage

// Апгрейд хранилища на файле (docs/plans/stage-12-reminders.md, B1, проба 0.9). Старую модель в тесте не воспроизвести
// (классы `@Model` одни), поэтому «старый» файл готовится текущей моделью, а апгрейд имитируется тем, что важно для
// синхронизации: в `SyncStateEntity.schemaVersion` пишется `GarageStore.schemaVersion - 1`, контейнер закрывается и
// открывается заново с того же URL, затем `SyncSupport.prepare`. Реальную смену модели проверила проба 0.9.

private func makeStoreDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "GarageMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func sync(_ container: ModelContainer, with server: FakeSyncServer) async throws -> SyncReport {
    let store = SwiftDataSyncStore(modelContainer: container)
    return try await SyncEngine(
        store: store, client: SyncAPIClient(transport: server, token: "t"), receipts: store
    ).sync()
}

/// Помечает хранилище так, будто оно создано предыдущей версией схемы.
private func downgradeSchemaVersion(_ container: ModelContainer, bootstrapped: Bool) throws {
    let context = ModelContext(container)
    let state = try SyncState.current(in: context)
    state.schemaVersion = GarageStore.schemaVersion - 1
    state.bootstrapped = bootstrapped
    try context.save()
}

private func pushedChanges(_ server: FakeSyncServer) async throws -> [PushChange] {
    var result: [PushChange] = []
    for request in await server.requests where request.method == "POST" && request.path == APIPath.changes {
        result += try APICoding.makeDecoder().decode(PushRequest.self, from: request.body ?? Data()).changes
    }
    return result
}

@Suite struct MigrationTests {
    /// Сценарий 1: bootstrap завершён. Очередь переживает «апгрейд» с теми же `changeID` и `baseVersion`, версии сущностей
    /// без pending удалены, курсор сброшен; push применяет правку, лишних строк в очереди нет.
    @Test func queueSurvivesSchemaBumpOnAFileWhenBootstrapIsDone() async throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "garage.store")
        let server = FakeSyncServer()
        let vehicle = Vehicle.samples[0]
        let synced = try makeSyncRecord(for: vehicle, notes: "синхронизирована")
        let edited = try makeSyncRecord(for: vehicle, notes: "до правки")
        var pendingBefore: PendingChange?
        var editedVersion: Int64?
        do {
            let container = try GarageStore.makeContainer(url: url)
            try VehicleLog.add(vehicle, in: container)
            try ServiceLog.add(synced, toVehicleWithID: vehicle.id, in: container)
            try ServiceLog.add(edited, toVehicleWithID: vehicle.id, in: container)
            try SyncSupport.prepare(container)
            _ = try await sync(container, with: server)
            var changed = edited
            changed.notes = "после правки"
            try ServiceLog.update(changed, receipt: .keep, in: container)
            let store = SwiftDataSyncStore(modelContainer: container)
            let ref = EntityRef(kind: .serviceRecord, id: edited.id)
            pendingBefore = try await store.pendingChange(for: ref)
            editedVersion = try await store.version(of: ref)
            try downgradeSchemaVersion(container, bootstrapped: true)
        }
        let before = try #require(pendingBefore)
        #expect(before.baseVersion == editedVersion)
        #expect(before.baseVersion != nil)

        let reopened = try GarageStore.makeContainer(url: url)
        try SyncSupport.prepare(reopened)

        let store = SwiftDataSyncStore(modelContainer: reopened)
        let after = try await store.pendingChanges()
        #expect(after.map(\.changeID) == [before.changeID])
        #expect(after.first?.baseVersion == before.baseVersion)
        #expect(try await store.cursor() == nil)
        // Положительный контроль: версия сущности без pending удалена.
        #expect(try await store.version(of: EntityRef(kind: .serviceRecord, id: synced.id)) == nil)
        #expect(try await store.version(of: EntityRef(kind: .vehicle, id: vehicle.id)) == nil)

        let report = try await sync(reopened, with: server)

        #expect(report.pushed == 1)
        #expect(report.conflictsResolved == 0)
        #expect(try await store.pendingChanges().isEmpty)
        let sent = try await pushedChanges(server).last
        #expect(sent?.changeID == before.changeID)
        #expect(sent?.baseVersion == before.baseVersion)
        #expect(await server.liveCount(.serviceRecord) == 2)
        #expect(await server.liveCount(.vehicle) == 1)
    }

    /// Сценарий 2 (R15): bootstrap не завершён. Сущности без pending и без версии снова встают в очередь как создание;
    /// сервер отвечает `conflict/alreadyExists`, движок разрешает по LWW: ничего не потеряно и не задублировано.
    @Test func unfinishedBootstrapRequeuesAsCreateAndResolvesByLWW() async throws {
        let directory = try makeStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "garage.store")
        let server = FakeSyncServer()
        let vehicle = Vehicle.samples[0]
        let record = try makeSyncRecord(for: vehicle, notes: "на сервере")
        do {
            let container = try GarageStore.makeContainer(url: url)
            try VehicleLog.add(vehicle, in: container)
            try ServiceLog.add(record, toVehicleWithID: vehicle.id, in: container)
            try SyncSupport.prepare(container)
            _ = try await sync(container, with: server)
            // Локальная копия потом изменилась мимо очереди: победитель LWW виден по полям.
            let context = ModelContext(container)
            let entity = try #require(try context.fetch(FetchDescriptor<ServiceRecordEntity>()).first)
            entity.notes = "локально новее"
            try context.save()
            try downgradeSchemaVersion(container, bootstrapped: false)
        }

        let reopened = try GarageStore.makeContainer(url: url)
        try SyncSupport.prepare(reopened)
        let store = SwiftDataSyncStore(modelContainer: reopened)
        let requeued = try await store.pendingChanges()
        #expect(requeued.count == 2)
        #expect(requeued.allSatisfy { $0.baseVersion == nil })

        let report = try await sync(reopened, with: server)

        #expect(report.conflictsResolved >= 1)
        #expect(try await store.pendingChanges().isEmpty)
        #expect(await server.liveCount(.vehicle) == 1)
        #expect(await server.liveCount(.serviceRecord) == 1)
        let context = ModelContext(reopened)
        let records = try context.fetch(FetchDescriptor<ServiceRecordEntity>())
        #expect(records.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<VehicleEntity>()) == 1)
        #expect(records.first?.notes == "локально новее")
    }
}
