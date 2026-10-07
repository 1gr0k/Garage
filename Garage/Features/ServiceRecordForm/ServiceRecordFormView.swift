import GarageCore
import PhotosUI
import SwiftUI

struct ServiceRecordFormView: View {
    typealias Field = ServiceRecordDraft.Field

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ServiceRecordFormViewModel
    @State private var photoItem: PhotosPickerItem?

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
                    errorText(.mileage)
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
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { if await viewModel.save() { dismiss() } }
                    }
                    .disabled(isPhotoPending || viewModel.isSaving)
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
        }
    }

    /// Фото выбрано, но ещё не готово (или его загрузка вот-вот начнётся).
    private var isPhotoPending: Bool { photoItem != nil && viewModel.receipt == nil }

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
            if let receipt = viewModel.receipt, let image = UIImage(data: receipt) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                Button("Remove Photo", role: .destructive) {
                    viewModel.removeReceipt()
                    photoItem = nil
                }
            } else {
                PhotosPicker("Attach Receipt Photo", selection: $photoItem, matching: .images)
            }
        }
        .task(id: photoItem) { await loadPhoto(photoItem) }
    }

    @ViewBuilder
    private func errorText(_ field: Field) -> some View {
        if let error = viewModel.errors[field] {
            Text(error.message).font(.footnote).foregroundStyle(.red)
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
        if viewModel.receipt == nil, !Task.isCancelled, item == photoItem { photoItem = nil }
    }
}

#Preview {
    let dependencies = AppDependencies.preview()
    return ServiceRecordFormView(
        viewModel: dependencies.makeServiceRecordFormViewModel(
            vehicleID: Vehicle.samples[0].id, currentMileageKm: 87_400))
}
