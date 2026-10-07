import GarageCore
import GarageStorage
import SwiftData
import SwiftUI

struct VehicleDetailView: View {
    @Environment(AppDependencies.self) private var dependencies
    let vehicleID: Vehicle.ID

    var body: some View {
        VehicleDetailContent(vehicleID: vehicleID, viewModel: dependencies.makeVehicleDetailViewModel())
    }
}

/// ViewModel лежит в `@State`: перерисовка родителя не должна сбрасывать диалог подтверждения.
private struct VehicleDetailContent: View {
    @Environment(AppDependencies.self) private var dependencies
    @Query private var vehicleEntities: [VehicleEntity]
    @Query private var recordEntities: [ServiceRecordEntity]
    @State private var viewModel: VehicleDetailViewModel
    @State private var isAddingRecord = false
    @State private var editing: ServiceRecordEditingSnapshot?

    init(vehicleID: Vehicle.ID, viewModel: VehicleDetailViewModel) {
        _vehicleEntities = Query(filter: #Predicate { $0.id == vehicleID })
        _recordEntities = Query(ServiceRecordEntity.descriptor(forVehicle: vehicleID))
        _viewModel = State(initialValue: viewModel)
    }

    private var receiptIDs: Set<UUID> {
        Set(recordEntities.lazy.filter(\.hasReceipt).map(\.id))
    }

    var body: some View {
        if let vehicle = vehicleEntities.validVehicles().first?.vehicle {
            content(vehicle: vehicle)
        } else {
            ContentUnavailableView("Vehicle Not Found", systemImage: "questionmark.circle")
        }
    }

    private func content(vehicle: Vehicle) -> some View {
        let records = recordEntities.validRecords()
        let receiptIDs = receiptIDs
        let mileage = vehicle.currentMileageKm(records: records)
        @Bindable var viewModel = viewModel
        return List {
            Section {
                LabeledContent("Mileage", value: mileage.kilometers)
                LabeledContent("Total spent", value: records.totalCost.formatted)
            }
            Section("Service History") {
                ForEach(records) { record in
                    Button {
                        editing = snapshot(of: record.id)
                    } label: {
                        ServiceRecordRow(record: record, hasReceipt: receiptIDs.contains(record.id))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Без `role: .destructive`: иначе List уберёт строку ещё до подтверждения.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete") { viewModel.pendingDeletion = record.id }
                            .tint(.red)
                            .disabled(viewModel.isDeleting)
                    }
                }
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("No Service Records", systemImage: "wrench.and.screwdriver")
                    .padding(.top, 120)
            }
        }
        .navigationTitle(vehicle.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Add Record", systemImage: "plus") { isAddingRecord = true }
        }
        .sheet(isPresented: $isAddingRecord) {
            ServiceRecordFormView(
                viewModel: dependencies.makeServiceRecordFormViewModel(
                    vehicleID: vehicle.id, currentMileageKm: mileage))
        }
        .sheet(item: $editing) { snapshot in
            // Пробег без самой записи: правка может его уменьшить.
            let others = records.filter { $0.id != snapshot.id }
            ServiceRecordFormView(
                viewModel: dependencies.makeServiceRecordFormViewModel(
                    editing: snapshot.record, hasStoredReceipt: snapshot.hasReceipt,
                    storedReceipt: snapshot.receiptImage,
                    currentMileageKm: vehicle.currentMileageKm(records: others)))
        }
        .confirmationDialog(
            "Delete this record?",
            isPresented: Binding(
                get: { viewModel.pendingDeletion != nil },
                set: { if !$0 { viewModel.pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: viewModel.pendingDeletion
        ) { id in
            Button("Delete Record", role: .destructive) {
                Task { await viewModel.delete(id: id) }
            }
        } message: { _ in
            Text("This can't be undone.")
        }
        .alert("Couldn't Delete", isPresented: $viewModel.deleteFailed) {
            Button("OK") {}
        } message: {
            Text("The record could not be deleted. Please try again.")
        }
    }

    private func snapshot(of id: ServiceRecord.ID) -> ServiceRecordEditingSnapshot? {
        guard let entity = recordEntities.first(where: { $0.id == id }) else { return nil }
        return try? entity.editingSnapshot()
    }
}

private struct ServiceRecordRow: View {
    let record: ServiceRecord
    let hasReceipt: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.serviceType.title)
                    .font(.headline)
                Text(
                    verbatim:
                        "\(record.date.formatted(date: .abbreviated, time: .omitted)) · \(record.mileageKm.kilometers)"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if !record.parts.isEmpty {
                    Text("\(record.parts.count) parts")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hasReceipt {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Has receipt")
            }
            Text(record.totalCost.formatted)
                .monospacedDigit()
        }
    }
}
