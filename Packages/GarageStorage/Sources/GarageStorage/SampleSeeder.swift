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
    public static func seedIfNeeded(_ context: ModelContext, defaults: UserDefaults = .standard) throws {
        guard !defaults.bool(forKey: didSeedKey) else { return }
        insertSamples(into: context)
        try context.save()
        defaults.set(true, forKey: didSeedKey)
    }
}
