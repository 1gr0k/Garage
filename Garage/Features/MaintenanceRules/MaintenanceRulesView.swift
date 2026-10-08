import GarageCore
import GarageStorage
import SwiftData
import SwiftUI

/// Экран напоминаний машины: правила со статусом, добавление, правка и удаление.
struct MaintenanceRulesView: View {
    @Environment(AppDependencies.self) private var dependencies
    let vehicleID: Vehicle.ID

    var body: some View {
        MaintenanceRulesContent(vehicleID: vehicleID, viewModel: dependencies.makeMaintenanceRulesViewModel())
    }
}

/// ViewModel лежит в `@State`: перерисовка родителя не должна сбрасывать диалог подтверждения.
private struct MaintenanceRulesContent: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @Query private var vehicleEntities: [VehicleEntity]
    @Query private var ruleEntities: [MaintenanceRuleEntity]
    @Query private var recordEntities: [ServiceRecordEntity]
    @State private var viewModel: MaintenanceRulesViewModel
    // Данные для формы снимаются в момент открытия; шит висит на `body`, а не на ветке с содержимым: если машину
    // удалят на другом устройстве, форма останется открытой и покажет `vehicleGone` при сохранении.
    @State private var formRequest: FormRequest?

    private enum FormRequest: Identifiable {
        case add(vehicleID: Vehicle.ID, currentMileageKm: Int)
        case edit(MaintenanceRuleEditingSnapshot)

        var id: UUID {
            switch self {
            case .add(let vehicleID, _): vehicleID
            case .edit(let snapshot): snapshot.id
            }
        }
    }

    init(vehicleID: Vehicle.ID, viewModel: MaintenanceRulesViewModel) {
        _vehicleEntities = Query(filter: #Predicate { $0.id == vehicleID })
        _ruleEntities = Query(filter: #Predicate { $0.vehicle?.id == vehicleID })
        _recordEntities = Query(ServiceRecordEntity.descriptor(forVehicle: vehicleID))
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if let item = vehicleEntities.validVehicles().first {
                content(vehicle: item.vehicle)
            } else {
                ContentUnavailableView("Vehicle Not Found", systemImage: "questionmark.circle")
            }
        }
        // Форма могла спросить разрешение: баннер перечитывает статус после её закрытия.
        .sheet(item: $formRequest, onDismiss: { Task { await viewModel.refreshAuthorization() } }) { request in
            switch request {
            case .add(let vehicleID, let currentMileageKm):
                MaintenanceRuleFormView(
                    viewModel: dependencies.makeMaintenanceRuleFormViewModel(
                        vehicleID: vehicleID, currentMileageKm: currentMileageKm))
            case .edit(let snapshot):
                MaintenanceRuleFormView(
                    viewModel: dependencies.makeMaintenanceRuleFormViewModel(
                        editing: snapshot.rule, unrecognizedPeriod: snapshot.rawPeriod))
            }
        }
        // При открытии и при возвращении в приложение: пользователь мог изменить уведомления в Настройках.
        .task(id: scenePhase) {
            if scenePhase == .active { await viewModel.refreshAuthorization() }
        }
    }

    private func content(vehicle: Vehicle) -> some View {
        let today = dependencies.today()
        let calendar = dependencies.calendar()
        let records = recordEntities.validRecords()
        let statuses = MaintenanceOverview.statuses(
            rules: ruleEntities.validRules(), vehicle: vehicle, records: records, today: today, calendar: calendar)
        let currentMileage = vehicle.currentMileageKm(records: records)
        @Bindable var viewModel = viewModel
        return List {
            if viewModel.notificationsDenied {
                Section {
                    Label("Notifications are off", systemImage: "bell.slash")
                        .accessibilityIdentifier(AccessibilityID.MaintenanceRules.notificationsOff)
                    Button("Open Settings") { viewModel.openSettings() }
                        .accessibilityIdentifier(AccessibilityID.MaintenanceRules.openSettings)
                }
            } else if viewModel.canRequestAuthorization, statuses.contains(where: { $0.rule.period != nil }) {
                // Правила могли прийти синхронизацией: форма их не создавала и разрешение не спрашивала.
                Section {
                    Button("Turn On Notifications", systemImage: "bell.badge") {
                        Task { await viewModel.requestAuthorization() }
                    }
                    .accessibilityIdentifier(AccessibilityID.MaintenanceRules.enableNotifications)
                }
            }
            // Пустое состояние — строка списка, а не оверлей: оверлей закрыл бы баннер уведомлений.
            if statuses.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Reminders", systemImage: "bell", description: Text("Tap + to add a service reminder.")
                    )
                    .accessibilityIdentifier(AccessibilityID.MaintenanceRules.empty)
                }
            }
            Section {
                ForEach(statuses) { status in
                    Button {
                        formRequest = editRequest(for: status.id)
                    } label: {
                        MaintenanceRuleRow(status: status, today: today, calendar: calendar)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.MaintenanceRules.row(status.id))
                    // Без `role: .destructive`: иначе List уберёт строку ещё до подтверждения.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete") { viewModel.pendingDeletion = status.id }
                            .tint(.red)
                            .disabled(viewModel.isDeleting)
                            .accessibilityIdentifier(AccessibilityID.MaintenanceRules.swipeDelete)
                    }
                }
            } footer: {
                if !statuses.isEmpty {
                    Text("Mileage reminders appear only in the app.")
                }
            }
        }
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Add Reminder", systemImage: "plus") {
                formRequest = .add(vehicleID: vehicle.id, currentMileageKm: currentMileage)
            }
            .accessibilityIdentifier(AccessibilityID.MaintenanceRules.add)
        }
        .confirmationDialog(
            "Delete this reminder?", item: $viewModel.pendingDeletion, titleVisibility: .visible
        ) { id in
            Button("Delete Reminder", role: .destructive) {
                Task { await viewModel.delete(id: id) }
            }
            .accessibilityIdentifier(AccessibilityID.MaintenanceRules.confirmDelete)
        } message: { _ in
            Text("This can't be undone.")
        }
        .alert("Couldn't Delete", isPresented: $viewModel.deleteFailed) {
            Button("OK") {}
        } message: {
            Text("The reminder could not be deleted. Please try again.")
        }
    }

    private func editRequest(for id: MaintenanceRule.ID) -> FormRequest? {
        guard let entity = ruleEntities.first(where: { $0.id == id }), let snapshot = try? entity.editingSnapshot()
        else { return nil }
        return .edit(snapshot)
    }
}

#Preview {
    let dependencies = AppDependencies.preview()
    return NavigationStack { MaintenanceRulesView(vehicleID: Vehicle.SampleID.landCruiser) }
        .modelContainer(dependencies.container)
        .environment(dependencies)
}
