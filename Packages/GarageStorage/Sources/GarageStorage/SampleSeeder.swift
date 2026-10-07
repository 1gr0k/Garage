import Foundation
import GarageCore
import SwiftData

public enum SampleSeeder {
    static let didSeedKey = "GarageStorage.didSeedSamples"

    public static func insertSamples(into context: ModelContext) {
        for vehicle in Vehicle.samples {
            context.insert(VehicleEntity(vehicle))
        }
    }

    /// Inserts the sample vehicles once per install. The flag is set only after a successful save.
    ///
    /// Works in its own `ModelContext`, so it can run off the main thread.
    public static func seedIfNeeded(_ container: ModelContainer, defaults: UserDefaults = .standard) throws {
        guard !defaults.bool(forKey: didSeedKey) else { return }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        insertSamples(into: context)
        try context.save()
        defaults.set(true, forKey: didSeedKey)
    }
}
