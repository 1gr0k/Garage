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
        let unrecognizedKind: String?
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
            if let item = vehicleEntities.validVehicles().first {
                content(vehicle: item.vehicle, rawKind: item.rawKind)
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
                    editing: request.vehicle, unrecognizedKind: request.unrecognizedKind,
                    recordsMileageKm: request.recordsMileageKm))
        }
        .sheet(item: $recordEdit) { request in
            ServiceRecordFormView(
                viewModel: dependencies.makeServiceRecordFormViewModel(
                    editing: request.snapshot.record, hasStoredReceipt: request.snapshot.hasReceipt,
                    storedReceipt: request.snapshot.receiptImage, currentMileageKm: request.currentMileageKm))
        }
    }

    private func content(vehicle: Vehicle, rawKind: String?) -> some View {
        let records = recordEntities.validRecords()
        let receiptIDs = receiptIDs
        let mileage = vehicle.currentMileageKm(records: records)
        @Bindable var viewModel = viewModel
        return List {
            VehicleSummarySection(mileage: mileage, totalCost: records.totalCost)
            ServiceHistorySection(
                records: records, receiptIDs: receiptIDs, isDeleting: viewModel.isDeleting,
                onOpen: { id in recordEdit = recordEditRequest(for: id, vehicle: vehicle, records: records) },
                onDelete: { viewModel.pendingDeletion = $0 })
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
            VehicleDetailToolbar(
                isDeleting: viewModel.isDeleting,
                onAddRecord: { newRecord = NewRecordRequest(vehicleID: vehicle.id, currentMileageKm: mileage) },
                onEdit: {
                    vehicleEdit = VehicleEditRequest(
                        vehicle: vehicle, unrecognizedKind: rawKind, recordsMileageKm: records.map(\.mileageKm).max())
                },
                onDeleteVehicle: { viewModel.isConfirmingVehicleDeletion = true })
        }
        // Диалоги и алерты остаются здесь: они привязаны к ViewModel, а шиты — к `body` (комментарий выше).
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
            "Delete this record?", item: $viewModel.pendingDeletion, titleVisibility: .visible
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
