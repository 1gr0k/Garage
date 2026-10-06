import Foundation
import GarageCore
import SwiftData
import Testing

@testable import GarageStorage

private func makeDefaults() -> UserDefaults {
    UserDefaults(suiteName: UUID().uuidString)!
}

@Test func seedingRunsOnce() throws {
    let context = ModelContext(try GarageStore.makeContainer(inMemory: true))
    let defaults = makeDefaults()

    try SampleSeeder.seedIfNeeded(context, defaults: defaults)
    #expect(try context.fetchCount(FetchDescriptor<VehicleEntity>()) == 4)
    #expect(defaults.bool(forKey: SampleSeeder.didSeedKey))

    try SampleSeeder.seedIfNeeded(context, defaults: defaults)
    #expect(try context.fetchCount(FetchDescriptor<VehicleEntity>()) == 4)
}

@Test func seedingDoesNotRepeatAfterDeletingAll() throws {
    let context = ModelContext(try GarageStore.makeContainer(inMemory: true))
    let defaults = makeDefaults()
    try SampleSeeder.seedIfNeeded(context, defaults: defaults)

    try context.delete(model: VehicleEntity.self)
    try context.save()
    try SampleSeeder.seedIfNeeded(context, defaults: defaults)

    #expect(try context.fetchCount(FetchDescriptor<VehicleEntity>()) == 0)
}
