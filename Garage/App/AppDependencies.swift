import Foundation
import GarageCore
import GarageStorage
import GarageSync
import OSLog
import Observation
import SwiftData
import UIKit

private let reminderLogger = Logger(subsystem: "Garage", category: "Reminders")

/// Composition root: единственное место, где приложение создаёт адаптеры хранилища и сети
/// и собирает из них use case'ы и ViewModel.
@Observable
final class AppDependencies {
    let container: ModelContainer
    /// Один на приложение: состояние синхронизации общее для всех экранов.
    let syncViewModel: SyncViewModel

    private let addServiceRecord: AddServiceRecord
    private let updateServiceRecord: UpdateServiceRecord
    private let recordEditing: any ServiceRecordEditing
    private let receiptPreparer: any ReceiptImagePreparing
    private let addVehicle: AddVehicle
    private let updateVehicle: UpdateVehicle
    private let vehicleRepository: any VehicleRepository
    private let currentYear: () -> Int

    // Напоминания о ТО (этап 12). Как и остальные порты, не торчат во вью: ViewModel экрана правил и формы
    // получают их через фабрики `makeMaintenanceRule*ViewModel`.
    private let ruleRepository: any MaintenanceRuleRepository
    private let addMaintenanceRule: AddMaintenanceRule
    private let updateMaintenanceRule: UpdateMaintenanceRule
    private let reminderScheduler: any ReminderScheduling
    /// Один на приложение: единственный запускатель пересчёта уведомлений.
    let reminderCoordinator: ReminderCoordinator
    /// «Сегодня» и календарь для сроков во вью; UI-режим фиксирует их (решение 12).
    let today: @Sendable () -> Date
    let calendar: @Sendable () -> Calendar

    /// - Parameters:
    ///   - reminderScheduler: боевой по умолчанию; тесты, превью и UI-режим подставляют свой.
    ///   - today: «сейчас» для сроков; UI-режим фиксирует дату фикстуры (`UITestFixture.today`, решение 12).
    ///   - calendar: календарь для сроков; UI-режим фиксирует часовой пояс фикстуры.
    init(
        container: ModelContainer,
        credentials: any SyncCredentialsStore = KeychainCredentialsStore(),
        registrar: any DeviceRegistrar = SyncAPIDeviceRegistrar(),
        reminderScheduler: any ReminderScheduling = UserNotificationsReminderScheduler(),
        today: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { Calendar.current },
        deviceName: @escaping @MainActor () -> String = { UIDevice.current.name }
    ) {
        self.container = container
        let service = SwiftDataSyncService(container: container, credentials: credentials)
        syncViewModel = SyncViewModel(
            service: service,
            registerDevice: RegisterDevice(registrar: registrar, credentials: credentials),
            syncNow: SyncNow(service: service, credentials: credentials),
            forgetDevice: ForgetDevice(service: service, credentials: credentials),
            credentials: credentials,
            deviceName: deviceName)
        // Один адаптер реализует оба порта: добавление и правку/удаление.
        let recordRepository = SwiftDataServiceRecordRepository(container: container)
        addServiceRecord = AddServiceRecord(records: recordRepository)
        updateServiceRecord = UpdateServiceRecord(records: recordRepository)
        recordEditing = recordRepository
        receiptPreparer = ImageIOReceiptPreparer()
        let vehicles = SwiftDataVehicleRepository(container: container)
        addVehicle = AddVehicle(vehicles: vehicles)
        updateVehicle = UpdateVehicle(vehicles: vehicles)
        vehicleRepository = vehicles
        currentYear = { Calendar.current.component(.year, from: Date()) }

        let rules = SwiftDataMaintenanceRuleRepository(container: container)
        ruleRepository = rules
        addMaintenanceRule = AddMaintenanceRule(rules: rules)
        updateMaintenanceRule = UpdateMaintenanceRule(rules: rules)
        self.reminderScheduler = reminderScheduler
        self.today = today
        self.calendar = calendar
        let reschedule = RescheduleReminders(snapshot: rules, scheduler: reminderScheduler)
        let coordinator = ReminderCoordinator {
            do {
                try await reschedule.execute(now: today(), calendar: calendar())
            } catch {
                reminderLogger.error("Reminder recalculation failed: \(error)")
            }
        }
        // Любое сохранение (запись, правка, каскад, pull) и первый запуск → пересчёт; дальше — `active` из `RootView`.
        coordinator.observe(StoreChanges.saves(of: container))
        coordinator.noteChange()
        reminderCoordinator = coordinator
    }

    func makeVehicleFormViewModel() -> VehicleFormViewModel {
        VehicleFormViewModel(
            mode: .add, addVehicle: addVehicle, updateVehicle: updateVehicle, currentYear: currentYear)
    }

    /// Форма правки. `recordsMileageKm` — пробег по записям для подсказки (считает вызывающий).
    func makeVehicleFormViewModel(
        editing vehicle: Vehicle, unrecognizedKind: String? = nil, recordsMileageKm: Int?
    ) -> VehicleFormViewModel {
        VehicleFormViewModel(
            mode: .edit(original: vehicle, unrecognizedKind: unrecognizedKind), recordsMileageKm: recordsMileageKm,
            addVehicle: addVehicle, updateVehicle: updateVehicle, currentYear: currentYear)
    }

    func makeVehicleListViewModel() -> VehicleListViewModel {
        VehicleListViewModel(vehicles: vehicleRepository)
    }

    func makeServiceRecordFormViewModel(vehicleID: Vehicle.ID, currentMileageKm: Int) -> ServiceRecordFormViewModel {
        ServiceRecordFormViewModel(
            mode: .add(vehicleID: vehicleID), currentMileageKm: currentMileageKm,
            addServiceRecord: addServiceRecord, updateServiceRecord: updateServiceRecord, records: recordEditing,
            receiptPreparer: receiptPreparer)
    }

    /// Форма правки. `currentMileageKm` — пробег машины без учёта самой записи (считает вызывающий).
    func makeServiceRecordFormViewModel(
        editing record: ServiceRecord, hasStoredReceipt: Bool, storedReceipt: Data?, currentMileageKm: Int
    ) -> ServiceRecordFormViewModel {
        ServiceRecordFormViewModel(
            mode: .edit(original: record, hasStoredReceipt: hasStoredReceipt), currentMileageKm: currentMileageKm,
            storedReceipt: storedReceipt, addServiceRecord: addServiceRecord,
            updateServiceRecord: updateServiceRecord, records: recordEditing, receiptPreparer: receiptPreparer)
    }

    func makeVehicleDetailViewModel() -> VehicleDetailViewModel {
        VehicleDetailViewModel(records: recordEditing, vehicles: vehicleRepository)
    }

    func makeMaintenanceRulesViewModel() -> MaintenanceRulesViewModel {
        MaintenanceRulesViewModel(
            rules: ruleRepository, scheduler: reminderScheduler,
            openSettings: {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            },
            permissionChanged: { [reminderCoordinator] in reminderCoordinator.noteChange() })
    }

    /// Форма нового правила. `currentMileageKm` — пробег машины (стартовое «последнее ТО было»).
    func makeMaintenanceRuleFormViewModel(
        vehicleID: Vehicle.ID, currentMileageKm: Int
    ) -> MaintenanceRuleFormViewModel {
        MaintenanceRuleFormViewModel(
            mode: .add(vehicleID: vehicleID, currentMileageKm: currentMileageKm), today: today(),
            addRule: addMaintenanceRule, updateRule: updateMaintenanceRule, rules: ruleRepository,
            scheduler: reminderScheduler,
            permissionChanged: { [reminderCoordinator] in reminderCoordinator.noteChange() })
    }

    /// Форма правки. `unrecognizedPeriod` — сырой период, которого клиент не понял (см. `MaintenanceRuleDraft`).
    func makeMaintenanceRuleFormViewModel(
        editing rule: MaintenanceRule, unrecognizedPeriod: String?
    ) -> MaintenanceRuleFormViewModel {
        MaintenanceRuleFormViewModel(
            mode: .edit(original: rule, unrecognizedPeriod: unrecognizedPeriod), today: today(),
            addRule: addMaintenanceRule, updateRule: updateMaintenanceRule, rules: ruleRepository,
            scheduler: reminderScheduler,
            permissionChanged: { [reminderCoordinator] in reminderCoordinator.noteChange() })
    }

    /// Боевой запуск: хранилище готовится вне главного потока, затем собираются зависимости.
    static func bootstrap() async throws -> AppDependencies {
        AppDependencies(container: try await AppBootstrap.prepare())
    }

    /// Рабочие зависимости на in-memory хранилище с демо-данными, для превью.
    static func preview() -> AppDependencies {
        let container = try! GarageStore.makeContainer(inMemory: true)
        SampleSeeder.insertSamples(into: container.mainContext)
        return AppDependencies(container: container, reminderScheduler: DisabledReminderScheduler())
    }
}

/// Планировщик, который ничего не ставит: превью и тесты не должны трогать настоящий центр уведомлений.
nonisolated struct DisabledReminderScheduler: ReminderScheduling {
    func authorization() async -> ReminderAuthorization { .denied }
    func requestAuthorization() async -> ReminderAuthorization { .denied }
    func replaceAll(with reminders: [ScheduledReminder]) async throws {}
}
