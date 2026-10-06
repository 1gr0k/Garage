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

    private var vehicles: [(vehicle: Vehicle, recordCount: Int)] {
        entities.compactMap { entity in
            do {
                return (try entity.toDomain(), entity.serviceRecords.count)
            } catch {
                logger.error("Skipping invalid vehicle \(entity.id, privacy: .public): \(error)")
                return nil
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(vehicles, id: \.vehicle.id) { vehicle, recordCount in
                NavigationLink(value: vehicle.id) {
                    VStack(alignment: .leading) {
                        Text(vehicle.displayName)
                            .font(.headline)
                        HStack(spacing: 0) {
                            Text(verbatim: "\(String(vehicle.year)) · ")
                            Text("\(recordCount) records")
                        }
                        .accessibilityElement(children: .combine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationDestination(for: Vehicle.ID.self) { VehicleDetailView(vehicleID: $0) }
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
