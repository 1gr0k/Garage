import GarageCore
import GarageStorage
import SwiftData
import SwiftUI

struct VehicleListView: View {
    @Query(sort: [SortDescriptor(\VehicleEntity.make), SortDescriptor(\VehicleEntity.model)])
    private var entities: [VehicleEntity]

    @State private var isShowingSyncSettings = false

    var body: some View {
        let vehicles = entities.validVehicles()
        NavigationStack {
            List(vehicles) { item in
                NavigationLink(value: item.id) {
                    VStack(alignment: .leading) {
                        Text(item.vehicle.displayName)
                            .font(.headline)
                        HStack(spacing: 0) {
                            Text(verbatim: "\(String(item.vehicle.year)) · ")
                            Text("\(item.recordCount) records")
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
            .toolbar {
                Button("Synchronization", systemImage: "arrow.triangle.2.circlepath") {
                    isShowingSyncSettings = true
                }
            }
            .sheet(isPresented: $isShowingSyncSettings) {
                NavigationStack { SyncSettingsView() }
            }
        }
    }
}

#Preview {
    let dependencies = AppDependencies.preview()
    return VehicleListView()
        .modelContainer(dependencies.container)
        .environment(dependencies)
        .environment(dependencies.syncViewModel)
}
