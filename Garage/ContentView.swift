import GarageCore
import GarageStorage
import OSLog
import Playgrounds
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Garage", category: "Storage")

struct ContentView: View {
    @Query(sort: [SortDescriptor(\VehicleEntity.make), SortDescriptor(\VehicleEntity.model)])
    private var entities: [VehicleEntity]

    private var vehicles: [Vehicle] {
        entities.compactMap { entity in
            do {
                return try entity.toDomain()
            } catch {
                logger.error("Skipping invalid vehicle \(entity.id, privacy: .public): \(error)")
                return nil
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(vehicles) { vehicle in
                VStack(alignment: .leading) {
                    Text(vehicle.displayName)
                        .font(.headline)
                    Text(String(vehicle.year))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                if vehicles.isEmpty {
                    ContentUnavailableView("No Vehicles", systemImage: "car")
                }
            }
            .navigationTitle("Garage")
        }
    }
}

#Preview {
    let container = try! GarageStore.makeContainer(inMemory: true)
    SampleSeeder.insertSamples(into: container.mainContext)
    return ContentView()
        .modelContainer(container)
}

#Playground {
    _ = 1 + 2
}
