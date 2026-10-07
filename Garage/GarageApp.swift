import GarageStorage
import SwiftData
import SwiftUI

@main struct GarageApp: App {
    private let container: ModelContainer
    @State private var syncController: SyncController

    init() {
        do {
            let container = try GarageStore.makeContainer()
            try SampleSeeder.seedIfNeeded(container)
            try SyncSupport.prepare(container)
            self.container = container
            _syncController = State(initialValue: SyncController(container: container))
        } catch {
            fatalError("Failed to set up the garage store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
        .environment(syncController)
    }
}
