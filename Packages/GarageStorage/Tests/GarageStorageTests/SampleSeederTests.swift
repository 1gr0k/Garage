import Foundation
import GarageCore
import SwiftData
import Testing

@testable import GarageStorage

private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: UUID().uuidString)!
}

@Test func seedingRunsOnce() throws {
    let container = try GarageStore.makeContainer(inMemory: true)
    let context = ModelContext(container)
    let defaults = makeDefaults()

    try SampleSeeder.seedIfNeeded(container, defaults: defaults)
    #expect(try context.fetchCount(FetchDescriptor<VehicleEntity>()) == 4)
    #expect(defaults.bool(forKey: SampleSeeder.didSeedKey))

    try SampleSeeder.seedIfNeeded(container, defaults: defaults)
    #expect(try context.fetchCount(FetchDescriptor<VehicleEntity>()) == 4)
}

/// Пункт 4 плана: удалённая демо-машина не возвращается ни сидом, ни bootstrap, ни «Забыть устройство».
@Test func seedingDoesNotRecreateDeletedSampleVehicle() throws {
    let container = try GarageStore.makeContainer(inMemory: true)
    let defaults = makeDefaults()
    try SampleSeeder.seedIfNeeded(container, defaults: defaults)
    try SyncSupport.prepare(container)
    try VehicleLog.delete(id: Vehicle.SampleID.landCruiser, in: container)

    try SampleSeeder.seedIfNeeded(container, defaults: defaults)
    try SyncSupport.prepare(container)
    try SyncSupport.resetSyncState(container)

    let context = ModelContext(container)
    let vehicles = try context.fetch(FetchDescriptor<VehicleEntity>())
    #expect(vehicles.count == 3)
    #expect(!vehicles.contains { $0.id == Vehicle.SampleID.landCruiser })
    let queued = try context.fetch(FetchDescriptor<PendingChangeEntity>())
    let upserts = try queued.map { try SyncQueue.pendingChange($0).operation }.filter { !$0.isDelete }
    #expect(!upserts.contains { $0.ref.id == Vehicle.SampleID.landCruiser })
}

@Test func seedingDoesNotRepeatAfterDeletingAll() throws {
    let container = try GarageStore.makeContainer(inMemory: true)
    let context = ModelContext(container)
    let defaults = makeDefaults()
    try SampleSeeder.seedIfNeeded(container, defaults: defaults)

    try context.delete(model: VehicleEntity.self)
    try context.save()
    try SampleSeeder.seedIfNeeded(container, defaults: defaults)

    #expect(try context.fetchCount(FetchDescriptor<VehicleEntity>()) == 0)
}
