import GarageCore
import SwiftUI

struct MaintenanceRuleFormView: View {
    typealias Field = MaintenanceRuleDraft.Field

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: MaintenanceRuleFormViewModel
    @State private var isConfirmingDelete = false

    /// ViewModel лежит в `@State`: перерисовка родителя не должна сбрасывать введённое.
    init(viewModel: MaintenanceRuleFormViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $viewModel.draft.serviceTypeChoice) {
                        ForEach(ServiceTypeChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.serviceType)
                    if viewModel.draft.serviceTypeChoice == .other {
                        TextField("Describe the work", text: field(\.otherServiceTypeText, .otherServiceType))
                        errorText(.otherServiceType)
                    }
                }
                periodSection
                distanceSection
                Section {
                    DatePicker("Date", selection: $viewModel.draft.startDate, displayedComponents: .date)
                    LabeledContent("Mileage, km") {
                        TextField("", text: field(\.startMileageText, .startMileage))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.startMileage)
                    }
                    errorText(.startMileage)
                } header: {
                    Text("Last service")
                } footer: {
                    Text("Used until there is a service record of this type.")
                }
                if viewModel.isEditing {
                    Section {
                        Button("Delete Reminder", role: .destructive) { isConfirmingDelete = true }
                            .disabled(viewModel.isBusy)
                            .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.deleteRule)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(viewModel.isEditing ? "Edit Reminder" : "New Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.close)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        Task { if await viewModel.save() { dismiss() } }
                    }
                    .disabled(viewModel.isBusy)
                    .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.confirm)
                }
            }
            .alert("Couldn't Save", isPresented: $viewModel.saveFailed) {
                Button("OK") {}
            } message: {
                Text("The reminder could not be stored. Please try again.")
            }
            .alert("Couldn't Delete", isPresented: $viewModel.deleteFailed) {
                Button("OK") {}
            } message: {
                Text("The reminder could not be deleted. Please try again.")
            }
            .alert("Reminder Deleted", isPresented: $viewModel.ruleGone) {
                Button("OK") { dismiss() }
            } message: {
                Text("This reminder was deleted on another device.")
            }
            .alert("Vehicle Deleted", isPresented: $viewModel.vehicleGone) {
                Button("OK") { dismiss() }
            } message: {
                Text("This vehicle was deleted on another device.")
            }
            .confirmationDialog("Delete this reminder?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete Reminder", role: .destructive) {
                    Task { if await viewModel.delete() { dismiss() } }
                }
                .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.confirmDelete)
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    private var periodSection: some View {
        @Bindable var viewModel = viewModel
        return Section("By time") {
            Toggle("Repeat by time", isOn: $viewModel.draft.usesPeriod)
                .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.usesPeriod)
            if viewModel.draft.usesPeriod {
                LabeledContent("Every") {
                    HStack {
                        TextField("", text: field(\.periodValueText, .period))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.periodValue)
                        // `fixedSize`: на крупном шрифте поле числа не отбирает место у подписи единицы.
                        Picker("Unit", selection: $viewModel.draft.periodUnit) {
                            Text("Months").tag(PeriodUnit.months)
                            Text("Days").tag(PeriodUnit.days)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.periodUnit)
                    }
                }
                periodError
            } else if let raw = viewModel.draft.unrecognizedPeriod, viewModel.draft.keepsUnrecognizedPeriod {
                Text("Unknown time interval (\(raw))")
                    .foregroundStyle(.secondary)
            }
            errorText(.interval, id: AccessibilityID.MaintenanceRuleForm.intervalError)
        }
    }

    private var distanceSection: some View {
        @Bindable var viewModel = viewModel
        return Section {
            Toggle("Repeat by mileage", isOn: $viewModel.draft.usesDistance)
                .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.usesDistance)
            if viewModel.draft.usesDistance {
                LabeledContent("Every, km") {
                    TextField("", text: field(\.distanceText, .distance))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.distance)
                }
                errorText(.distance, id: AccessibilityID.MaintenanceRuleForm.distanceError)
            }
        } header: {
            Text("By mileage")
        } footer: {
            if viewModel.draft.usesDistance && !viewModel.draft.usesPeriod {
                Text("Mileage reminders appear only in the app.")
            }
        }
    }

    /// Ошибка интервала по времени называет границы выбранной единицы, а не обеих сразу.
    @ViewBuilder
    private var periodError: some View {
        if let error = viewModel.errors[.period] {
            let text =
                if case .invalid(.periodOutOfRange) = error {
                    switch viewModel.draft.periodUnit {
                    case .days:
                        Text("Enter from 1 to \(String(ServicePeriod.daysRange.upperBound)) days")
                    case .months:
                        Text("Enter from 1 to \(String(ServicePeriod.monthsRange.upperBound)) months")
                    }
                } else {
                    Text(error.message)
                }
            text.font(.footnote).foregroundStyle(.red)
                .accessibilityIdentifier(AccessibilityID.MaintenanceRuleForm.periodError)
        }
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
    private func field(_ keyPath: WritableKeyPath<MaintenanceRuleDraft, String>, _ field: Field) -> Binding<String> {
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
    return MaintenanceRuleFormView(
        viewModel: dependencies.makeMaintenanceRuleFormViewModel(
            vehicleID: Vehicle.SampleID.landCruiser, currentMileageKm: 87_400))
}
