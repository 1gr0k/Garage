import GarageCore
import PhotosUI
import SwiftUI

struct ServiceRecordFormView: View {
    typealias Field = ServiceRecordDraft.Field

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ServiceRecordFormViewModel
    @State private var photoItem: PhotosPickerItem?
    @State private var isConfirmingDelete = false

    /// ViewModel лежит в `@State`: перерисовка родителя не должна сбрасывать введённое.
    init(viewModel: ServiceRecordFormViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $viewModel.draft.date, displayedComponents: .date)
                    TextField("Mileage, km", text: field(\.mileageText, .mileage))
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier(AccessibilityID.ServiceRecordForm.mileage)
                    errorText(.mileage, id: AccessibilityID.ServiceRecordForm.mileageError)
                    if let value = viewModel.newMileageKm {
                        Text("Vehicle mileage will be \(value.kilometers)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("Type", selection: $viewModel.draft.serviceTypeChoice) {
                        ForEach(ServiceTypeChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if viewModel.draft.serviceTypeChoice == .other {
                        TextField("Describe the work", text: field(\.otherServiceTypeText, .otherServiceType))
                        errorText(.otherServiceType)
                    }
                    TextField("Labor cost", text: field(\.laborCostText, .laborCost))
                        .keyboardType(.decimalPad)
                    errorText(.laborCost)
                }
                partsSection
                Section("Notes") {
                    TextField("Notes", text: $viewModel.draft.notes, axis: .vertical)
                }
                receiptSection
                if viewModel.isEditing {
                    Section {
                        Button("Delete Record", role: .destructive) { isConfirmingDelete = true }
                            .disabled(viewModel.isBusy)
                            .accessibilityIdentifier(AccessibilityID.ServiceRecordForm.deleteRecord)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(viewModel.isEditing ? "Edit Record" : "New Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.ServiceRecordForm.close)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        Task { if await viewModel.save() { dismiss() } }
                    }
                    .disabled(isPhotoPending || viewModel.isBusy)
                    .accessibilityIdentifier(AccessibilityID.ServiceRecordForm.confirm)
                }
            }
            .alert("Couldn't Save", isPresented: $viewModel.saveFailed) {
                Button("OK") {}
            } message: {
                Text("The record could not be stored. Please try again.")
            }
            .alert("Couldn't Load Photo", isPresented: $viewModel.receiptFailed) {
                Button("OK") {}
            }
            .alert("Couldn't Delete", isPresented: $viewModel.deleteFailed) {
                Button("OK") {}
            } message: {
                Text("The record could not be deleted. Please try again.")
            }
            .alert("Record Deleted", isPresented: $viewModel.recordGone) {
                Button("OK") { dismiss() }
            } message: {
                Text("This record was deleted on another device.")
            }
            .alert("Vehicle Deleted", isPresented: $viewModel.vehicleGone) {
                Button("OK") { dismiss() }
            } message: {
                Text("This vehicle was deleted on another device.")
            }
            .confirmationDialog("Delete this record?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Record", role: .destructive) {
                    Task { if await viewModel.delete() { dismiss() } }
                }
                .accessibilityIdentifier(AccessibilityID.ServiceRecordForm.confirmDelete)
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    /// Фото выбрано, но ещё не готово: читается из библиотеки (`photoItem` сбрасывается по завершении)
    /// или подготавливается.
    private var isPhotoPending: Bool { photoItem != nil || viewModel.isPreparingReceipt }

    private var partsSection: some View {
        @Bindable var viewModel = viewModel
        return Section("Parts") {
            ForEach($viewModel.draft.parts) { $part in
                VStack(alignment: .leading) {
                    TextField("Name", text: field(for: part.id, \.name, .partName(part.id)))
                    errorText(.partName(part.id))
                    TextField("Part number", text: $part.partNumber)
                    TextField("Unit price", text: field(for: part.id, \.unitPriceText, .partUnitPrice(part.id)))
                        .keyboardType(.decimalPad)
                    errorText(.partUnitPrice(part.id))
                    TextField("Quantity", text: field(for: part.id, \.quantityText, .partQuantity(part.id)))
                        .keyboardType(.numberPad)
                    errorText(.partQuantity(part.id))
                }
            }
            .onDelete { offsets in
                let removed = offsets.map { viewModel.draft.parts[$0].id }
                removed.forEach(viewModel.removePart(id:))
            }
            Button("Add Part", systemImage: "plus") { viewModel.draft.parts.append(PartDraft()) }
        }
    }

    private var receiptSection: some View {
        Section("Receipt") {
            if let receipt = viewModel.receiptPreview, let image = UIImage(data: receipt) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                receiptButtons
            } else if viewModel.isReceiptPending {
                Text("The receipt photo hasn't been downloaded yet.")
                    .foregroundStyle(.secondary)
                receiptButtons
            } else {
                PhotosPicker("Attach Receipt Photo", selection: $photoItem, matching: .images)
                    .accessibilityIdentifier(AccessibilityID.ServiceRecordForm.attachPhoto)
            }
        }
        .task(id: photoItem) { await loadPhoto(photoItem) }
    }

    @ViewBuilder
    private var receiptButtons: some View {
        PhotosPicker("Replace Photo", selection: $photoItem, matching: .images)
            .accessibilityIdentifier(AccessibilityID.ServiceRecordForm.replacePhoto)
        Button("Remove Photo", role: .destructive) {
            viewModel.removeReceipt()
            photoItem = nil
        }
        .accessibilityIdentifier(AccessibilityID.ServiceRecordForm.removePhoto)
    }

    @ViewBuilder
    private func errorText(_ field: Field, id: String? = nil) -> some View {
        if let error = viewModel.errors[field] {
            let text = Text(error.message).font(.footnote).foregroundStyle(.red)
            if let id {
                text.accessibilityIdentifier(id)
            } else {
                text
            }
        }
    }

    /// Привязка к полю черновика; правка сбрасывает ошибку этого поля.
    private func field(_ keyPath: WritableKeyPath<ServiceRecordDraft, String>, _ field: Field) -> Binding<String> {
        Binding(
            get: { viewModel.draft[keyPath: keyPath] },
            set: {
                viewModel.draft[keyPath: keyPath] = $0
                viewModel.clearError(for: field)
            })
    }

    private func field(
        for id: UUID, _ keyPath: WritableKeyPath<PartDraft, String>, _ field: Field
    ) -> Binding<String> {
        Binding(
            get: { viewModel.draft.parts.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let index = viewModel.draft.parts.firstIndex(where: { $0.id == id }) else { return }
                viewModel.draft.parts[index][keyPath: keyPath] = newValue
                viewModel.clearError(for: field)
            })
    }

    /// Читает байты выбранного фото (`PhotosPickerItem` — тип UI) и отдаёт их ViewModel.
    /// Только загрузка для текущего выбора может менять состояние: отменённая или устаревшая молчит.
    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        let data = try? await item.loadTransferable(type: Data.self)
        guard !Task.isCancelled, item == photoItem else { return }
        await viewModel.loadReceipt(data)
        guard !Task.isCancelled, item == photoItem else { return }
        // Освобождаем выбор, чтобы тот же снимок можно было выбрать снова.
        photoItem = nil
    }
}

#Preview {
    let dependencies = AppDependencies.preview()
    return ServiceRecordFormView(
        viewModel: dependencies.makeServiceRecordFormViewModel(
            vehicleID: Vehicle.samples[0].id, currentMileageKm: 87_400))
}
