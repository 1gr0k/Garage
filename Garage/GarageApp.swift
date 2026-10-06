import GarageStorage
import SwiftData
import SwiftUI

@main struct GarageApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try GarageStore.makeContainer()
            try SampleSeeder.seedIfNeeded(container.mainContext)
        } catch {
            fatalError("Failed to set up the garage store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
