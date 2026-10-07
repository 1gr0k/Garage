import GarageCore
import GarageStorage
import SwiftData
import SwiftUI

struct VehicleListView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        VehicleListContent(viewModel: dependencies.makeVehicleListViewModel())
    }
}

/// ViewModel лежит в `@State`: перерисовка родителя не должна сбрасывать диалог подтверждения.
private struct VehicleListContent: View {
    @Environment(AppDependencies.self) private var dependencies
    @Query(sort: [SortDescriptor(\VehicleEntity.make), SortDescriptor(\VehicleEntity.model)])
    private var entities: [VehicleEntity]

    @State private var viewModel: VehicleListViewModel
    @State private var isShowingSyncSettings = false
    @State private var isAddingVehicle = false

    init(viewModel: VehicleListViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        let vehicles = entities.validVehicles()
        @Bindable var viewModel = viewModel
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
                // Без `role: .destructive`: иначе List уберёт строку ещё до подтверждения.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete") { viewModel.pendingDeletion = item.id }
                        .tint(.red)
                        .disabled(viewModel.isDeleting)
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
                Button("Add Vehicle", systemImage: "plus") { isAddingVehicle = true }
            }
            .sheet(isPresented: $isShowingSyncSettings) {
                NavigationStack { SyncSettingsView() }
            }
            .sheet(isPresented: $isAddingVehicle) {
                VehicleFormView(viewModel: dependencies.makeVehicleFormViewModel())
            }
            .confirmationDialog(
                "Delete this vehicle?",
                isPresented: Binding(
                    get: { viewModel.pendingDeletion != nil },
                    set: { if !$0 { viewModel.pendingDeletion = nil } }),
                titleVisibility: .visible,
                presenting: viewModel.pendingDeletion
            ) { id in
                Button("Delete Vehicle", role: .destructive) {
                    Task { await viewModel.delete(id: id) }
                }
            } message: { id in
                VehicleDeletionMessage(recordCount: vehicles.first { $0.id == id }?.recordCount ?? 0)
            }
            .alert("Couldn't Delete", isPresented: $viewModel.deleteFailed) {
                Button("OK") {}
            } message: {
                Text("The vehicle could not be deleted. Please try again.")
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
