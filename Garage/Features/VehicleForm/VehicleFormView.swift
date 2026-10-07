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
                        ForEach(VehicleKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    TextField("Make", text: field(\.make, .make))
                    errorText(.make)
                    TextField("Model", text: field(\.model, .model))
                    errorText(.model)
                    TextField("Year", text: field(\.yearText, .year))
                        .keyboardType(.numberPad)
                    errorText(.year)
                }
                Section {
                    TextField("Mileage, km", text: field(\.mileageText, .mileage))
                        .keyboardType(.numberPad)
                    errorText(.mileage)
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { if await viewModel.save() { dismiss() } }
                    }
                    .disabled(viewModel.isSaving)
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
    private func errorText(_ field: Field) -> some View {
        if let error = viewModel.errors[field] {
            Text(error.message).font(.footnote).foregroundStyle(.red)
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
