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
                        .accessibilityIdentifier(AccessibilityID.VehicleList.rowSubtitle(item.id))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.VehicleList.row(item.id))
                // Без `role: .destructive`: иначе List уберёт строку ещё до подтверждения.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete") { viewModel.pendingDeletion = item.id }
                        .tint(.red)
                        .disabled(viewModel.isDeleting)
                        .accessibilityIdentifier(AccessibilityID.VehicleList.swipeDelete)
                }
            }
            .navigationDestination(for: Vehicle.ID.self) { VehicleDetailView(vehicleID: $0) }
            .overlay {
                if vehicles.isEmpty {
                    ContentUnavailableView("No Vehicles", systemImage: "car")
                        .accessibilityIdentifier(AccessibilityID.VehicleList.empty)
                }
            }
            .navigationTitle("Garage")
            .toolbar {
                Button("Synchronization", systemImage: "arrow.triangle.2.circlepath") {
                    isShowingSyncSettings = true
                }
                .accessibilityIdentifier(AccessibilityID.VehicleList.sync)
                Button("Add Vehicle", systemImage: "plus") { isAddingVehicle = true }
                    .accessibilityIdentifier(AccessibilityID.VehicleList.add)
            }
            .sheet(isPresented: $isShowingSyncSettings) {
                NavigationStack { SyncSettingsView() }
            }
            .sheet(isPresented: $isAddingVehicle) {
                VehicleFormView(viewModel: dependencies.makeVehicleFormViewModel())
            }
            .confirmationDialog(
                "Delete this vehicle?", item: $viewModel.pendingDeletion, titleVisibility: .visible
            ) { id in
                Button("Delete Vehicle", role: .destructive) {
                    Task { await viewModel.delete(id: id) }
                }
                .accessibilityIdentifier(AccessibilityID.VehicleList.confirmDelete)
                Button("Cancel", role: .cancel) {}
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
