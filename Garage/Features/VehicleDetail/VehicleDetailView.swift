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
    @Environment(\.dismiss) private var dismiss
    // Данные для форм снимаются в момент открытия, а шиты висят на `body`, а не на ветке с содержимым:
    // если машину удалят на другом устройстве, форма останется открытой и покажет `vehicleGone` при сохранении.
    @State private var newRecord: NewRecordRequest?
    @State private var vehicleEdit: VehicleEditRequest?
    @State private var recordEdit: RecordEditRequest?

    private struct NewRecordRequest: Identifiable {
        let vehicleID: Vehicle.ID
        let currentMileageKm: Int
        var id: Vehicle.ID { vehicleID }
    }

    private struct VehicleEditRequest: Identifiable {
        let vehicle: Vehicle
        let recordsMileageKm: Int?
        var id: Vehicle.ID { vehicle.id }
    }

    private struct RecordEditRequest: Identifiable {
        let snapshot: ServiceRecordEditingSnapshot
        /// Пробег машины без самой записи: правка может его уменьшить.
        let currentMileageKm: Int
        var id: ServiceRecord.ID { snapshot.id }
    }

    init(vehicleID: Vehicle.ID, viewModel: VehicleDetailViewModel) {
        _vehicleEntities = Query(filter: #Predicate { $0.id == vehicleID })
        _recordEntities = Query(ServiceRecordEntity.descriptor(forVehicle: vehicleID))
        _viewModel = State(initialValue: viewModel)
    }

    private var receiptIDs: Set<UUID> {
        Set(recordEntities.lazy.filter(\.hasReceipt).map(\.id))
    }

    var body: some View {
        Group {
            if let vehicle = vehicleEntities.validVehicles().first?.vehicle {
                content(vehicle: vehicle)
            } else {
                ContentUnavailableView("Vehicle Not Found", systemImage: "questionmark.circle")
                    .accessibilityIdentifier(AccessibilityID.VehicleDetail.notFound)
            }
        }
        .sheet(item: $newRecord) { request in
            ServiceRecordFormView(
                viewModel: dependencies.makeServiceRecordFormViewModel(
                    vehicleID: request.vehicleID, currentMileageKm: request.currentMileageKm))
        }
        .sheet(item: $vehicleEdit) { request in
            VehicleFormView(
                viewModel: dependencies.makeVehicleFormViewModel(
                    editing: request.vehicle, recordsMileageKm: request.recordsMileageKm))
        }
        .sheet(item: $recordEdit) { request in
            ServiceRecordFormView(
                viewModel: dependencies.makeServiceRecordFormViewModel(
                    editing: request.snapshot.record, hasStoredReceipt: request.snapshot.hasReceipt,
                    storedReceipt: request.snapshot.receiptImage, currentMileageKm: request.currentMileageKm))
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
                        recordEdit = recordEditRequest(for: record.id, vehicle: vehicle, records: records)
                    } label: {
                        ServiceRecordRow(record: record, hasReceipt: receiptIDs.contains(record.id))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.VehicleDetail.record(record.id))
                    // Без `role: .destructive`: иначе List уберёт строку ещё до подтверждения.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete") { viewModel.pendingDeletion = record.id }
                            .tint(.red)
                            .disabled(viewModel.isDeleting)
                            .accessibilityIdentifier(AccessibilityID.VehicleDetail.swipeDeleteRecord)
                    }
                }
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("No Service Records", systemImage: "wrench.and.screwdriver")
                    .accessibilityIdentifier(AccessibilityID.VehicleDetail.noRecords)
                    .padding(.top, 120)
            }
        }
        .navigationTitle(vehicle.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Add Record", systemImage: "plus") {
                newRecord = NewRecordRequest(vehicleID: vehicle.id, currentMileageKm: mileage)
            }
            .disabled(viewModel.isDeleting)
            .accessibilityIdentifier(AccessibilityID.VehicleDetail.addRecord)
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Edit", systemImage: "pencil") {
                    vehicleEdit = VehicleEditRequest(
                        vehicle: vehicle, recordsMileageKm: records.map(\.mileageKm).max())
                }
                .disabled(viewModel.isDeleting)
                .accessibilityIdentifier(AccessibilityID.VehicleDetail.edit)
                Button("Delete Vehicle", systemImage: "trash", role: .destructive) {
                    viewModel.isConfirmingVehicleDeletion = true
                }
                .disabled(viewModel.isDeleting)
                .accessibilityIdentifier(AccessibilityID.VehicleDetail.deleteVehicle)
            }
            .accessibilityIdentifier(AccessibilityID.VehicleDetail.more)
        }
        .confirmationDialog(
            "Delete this vehicle?", isPresented: $viewModel.isConfirmingVehicleDeletion, titleVisibility: .visible
        ) {
            Button("Delete Vehicle", role: .destructive) {
                Task { if await viewModel.deleteVehicle(id: vehicle.id) { dismiss() } }
            }
            .accessibilityIdentifier(AccessibilityID.VehicleDetail.confirmDeleteVehicle)
            Button("Cancel", role: .cancel) {}
        } message: {
            VehicleDeletionMessage(recordCount: recordEntities.count)
        }
        .alert("Couldn't Delete", isPresented: $viewModel.vehicleDeleteFailed) {
            Button("OK") {}
        } message: {
            Text("The vehicle could not be deleted. Please try again.")
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
            .accessibilityIdentifier(AccessibilityID.VehicleDetail.confirmDeleteRecord)
        } message: { _ in
            Text("This can't be undone.")
        }
        .alert("Couldn't Delete", isPresented: $viewModel.deleteFailed) {
            Button("OK") {}
        } message: {
            Text("The record could not be deleted. Please try again.")
        }
    }

    private func recordEditRequest(
        for id: ServiceRecord.ID, vehicle: Vehicle, records: [ServiceRecord]
    ) -> RecordEditRequest? {
        guard let entity = recordEntities.first(where: { $0.id == id }),
            let snapshot = try? entity.editingSnapshot()
        else { return nil }
        let others = records.filter { $0.id != id }
        return RecordEditRequest(snapshot: snapshot, currentMileageKm: vehicle.currentMileageKm(records: others))
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
                    .accessibilityIdentifier(AccessibilityID.VehicleDetail.receiptClip(record.id))
            }
            Text(record.totalCost.formatted)
                .monospacedDigit()
        }
    }
}
