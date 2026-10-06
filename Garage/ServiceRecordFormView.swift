import GarageCore
import GarageStorage
import PhotosUI
import SwiftData
import SwiftUI

struct ServiceRecordFormView: View {
    typealias Field = ServiceRecordDraft.Field

    let vehicle: VehicleEntity
    let currentMileageKm: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var draft = ServiceRecordDraft()
    @State private var errors: [Field: ServiceRecordDraft.FieldError] = [:]
    @State private var photoItem: PhotosPickerItem?
    @State private var receipt: Data?
    @State private var isLoadingPhoto = false
    @State private var photoFailed = false
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $draft.date, displayedComponents: .date)
                    TextField("Mileage, km", text: field(\.mileageText, .mileage))
                        .keyboardType(.numberPad)
                    errorText(.mileage)
                    if let hint = mileageHint {
                        Text(hint).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("Type", selection: $draft.serviceTypeChoice) {
                        ForEach(ServiceTypeChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if draft.serviceTypeChoice == .other {
                        TextField("Describe the work", text: field(\.otherServiceTypeText, .otherServiceType))
                        errorText(.otherServiceType)
                    }
                    TextField("Labor cost", text: field(\.laborCostText, .laborCost))
                        .keyboardType(.decimalPad)
                    errorText(.laborCost)
                }
                partsSection
                Section("Notes") {
                    TextField("Notes", text: $draft.notes, axis: .vertical)
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
                    Button("Save", action: save)
                        .disabled(isLoadingPhoto)
                }
            }
            .alert("Couldn't Save", isPresented: $saveFailed) {
                Button("OK") {}
            } message: {
                Text("The record could not be stored. Please try again.")
            }
            .alert("Couldn't Load Photo", isPresented: $photoFailed) {
                Button("OK") {}
            }
        }
    }

    private var mileageHint: String? {
        guard let value = Int(draft.mileageText.filter { !$0.isWhitespace }), value > currentMileageKm else {
            return nil
        }
        return String(localized: "Vehicle mileage will be \(value.formatted()) km")
    }

    private var partsSection: some View {
        Section("Parts") {
            ForEach($draft.parts) { $part in
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
                let removed = offsets.map { draft.parts[$0].id }
                draft.parts.remove(atOffsets: offsets)
                errors = errors.filter { key, _ in !removed.contains { key.partID == $0 } }
            }
            Button("Add Part", systemImage: "plus") { draft.parts.append(PartDraft()) }
        }
    }

    private var receiptSection: some View {
        Section("Receipt") {
            if let receipt, let image = UIImage(data: receipt) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                Button("Remove Photo", role: .destructive) {
                    self.receipt = nil
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
        if let error = errors[field] {
            Text(error.message).font(.footnote).foregroundStyle(.red)
        }
    }

    /// A binding to a draft field that clears that field's error when edited.
    private func field(_ keyPath: WritableKeyPath<ServiceRecordDraft, String>, _ field: Field) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: {
                draft[keyPath: keyPath] = $0
                errors[field] = nil
            })
    }

    private func field(
        for id: UUID, _ keyPath: WritableKeyPath<PartDraft, String>, _ field: Field
    ) -> Binding<String> {
        Binding(
            get: { draft.parts.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let index = draft.parts.firstIndex(where: { $0.id == id }) else { return }
                draft.parts[index][keyPath: keyPath] = newValue
                errors[field] = nil
            })
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ReceiptImageError.unreadableImage
            }
            let prepared = try await Task.detached { try ReceiptImage.prepare(data) }.value
            try Task.checkCancellation()
            receipt = prepared
        } catch is CancellationError {
            // A newer selection replaced this one.
        } catch {
            photoItem = nil
            photoFailed = true
        }
    }

    private func save() {
        do {
            let record = try draft.makeRecord(vehicleID: vehicle.id)
            try ServiceLog.add(record, receiptImage: receipt, to: vehicle, in: modelContext)
            dismiss()
        } catch let failure as ServiceRecordDraft.Errors {
            errors = failure.fields
        } catch {
            saveFailed = true
        }
    }
}

extension ServiceRecordDraft.Field {
    fileprivate var partID: UUID? {
        switch self {
        case .partName(let id), .partUnitPrice(let id), .partQuantity(let id): id
        default: nil
        }
    }
}

#Preview {
    let container = try! GarageStore.makeContainer(inMemory: true)
    let vehicle = VehicleEntity(Vehicle.samples[0])
    container.mainContext.insert(vehicle)
    return ServiceRecordFormView(vehicle: vehicle, currentMileageKm: 87_400)
        .modelContainer(container)
}
