import GarageCore
import SwiftUI

struct VehicleFormView: View {
    typealias Field = VehicleDraft.Field

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: VehicleFormViewModel

    /// ViewModel лежит в `@State`: перерисовка родителя не должна сбрасывать введённое.
    init(viewModel: VehicleFormViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $viewModel.draft.kind) {
                        // Незнакомый серверный вид: вариант не выбран, пока пользователь не выберет явно.
                        if let raw = viewModel.draft.unrecognizedKind {
                            Text("Unknown kind (\(raw))").tag(VehicleKind?.none)
                        }
                        ForEach(VehicleKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .accessibilityIdentifier(AccessibilityID.VehicleForm.kind)
                }
                Section {
                    TextField("Make", text: field(\.make, .make))
                        .accessibilityIdentifier(AccessibilityID.VehicleForm.make)
                    errorText(.make, id: AccessibilityID.VehicleForm.makeError)
                    TextField("Model", text: field(\.model, .model))
                        .accessibilityIdentifier(AccessibilityID.VehicleForm.model)
                    errorText(.model, id: AccessibilityID.VehicleForm.modelError)
                    TextField("Year", text: field(\.yearText, .year))
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier(AccessibilityID.VehicleForm.year)
                    errorText(.year, id: AccessibilityID.VehicleForm.yearError)
                }
                Section {
                    TextField("Mileage, km", text: field(\.mileageText, .mileage))
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier(AccessibilityID.VehicleForm.mileage)
                    errorText(.mileage, id: AccessibilityID.VehicleForm.mileageError)
                    if let value = viewModel.recordsMileageHintKm {
                        Text("By records: \(value.kilometers)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(viewModel.isEditing ? "Edit Vehicle" : "New Vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.VehicleForm.close)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        Task { if await viewModel.save() { dismiss() } }
                    }
                    .disabled(viewModel.isSaving)
                    .accessibilityIdentifier(AccessibilityID.VehicleForm.confirm)
                }
            }
            .alert("Couldn't Save", isPresented: $viewModel.saveFailed) {
                Button("OK") {}
            } message: {
                Text("The vehicle could not be stored. Please try again.")
            }
            .alert("Vehicle Deleted", isPresented: $viewModel.vehicleGone) {
                Button("OK") { dismiss() }
            } message: {
                Text("This vehicle was deleted on another device.")
            }
        }
    }

    @ViewBuilder
    private func errorText(_ field: Field, id: String) -> some View {
        if let error = viewModel.errors[field] {
            Text(error.message).font(.footnote).foregroundStyle(.red)
                .accessibilityIdentifier(id)
        }
    }

    /// Привязка к полю черновика; правка сбрасывает ошибку этого поля.
    private func field(_ keyPath: WritableKeyPath<VehicleDraft, String>, _ field: Field) -> Binding<String> {
        Binding(
            get: { viewModel.draft[keyPath: keyPath] },
            set: {
                viewModel.draft[keyPath: keyPath] = $0
                viewModel.clearError(for: field)
            })
    }
}

#Preview {
    let dependencies = AppDependencies.preview()
    return VehicleFormView(viewModel: dependencies.makeVehicleFormViewModel())
}
