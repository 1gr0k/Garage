import Foundation

#if DEBUG
    import GarageCore
    import GarageStorage
    import Synchronization
    import UIKit

    extension AppDependencies {
        /// Запуск приложения: боевой или тестовый (по аргументу `-GarageUITesting`, только Debug).
        static var launchBootstrap: () async throws -> AppDependencies {
            ProcessInfo.processInfo.arguments.contains(UITestFixture.launchArgument)
                ? bootstrapForUITesting : bootstrap
        }

        /// Тестовый режим: SwiftData в памяти, изолированный `UserDefaults`, свежий сид и фикстура записей,
        /// синхронизация выключена (нет токена в Keychain, регистрация не ходит в сеть).
        static func bootstrapForUITesting() async throws -> AppDependencies {
            let suiteName = "Garage.UITests"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw UITestingError.defaultsUnavailable
            }
            defaults.removePersistentDomain(forName: suiteName)
            let container = try await AppBootstrap.prepare(inMemory: true, defaults: defaults)
            // Обычный путь записи через порт: в очередь синхронизации ставятся изменения, отправлять их некому.
            let repository = SwiftDataServiceRecordRepository(container: container)
            let records = try fixtureRecords()
            // Фикстура и её описание для тестов не должны разойтись.
            let actualCounts = Dictionary(grouping: records, by: \.0.vehicleID).mapValues(\.count)
            for (vehicleID, expected) in UITestFixture.recordCounts
            where actualCounts[vehicleID, default: 0] != expected {
                throw UITestingError.fixtureMismatch(vehicleID)
            }
            for (record, receipt) in records {
                try await repository.add(record, receiptImage: receipt)
            }
            let ruleRepository = SwiftDataMaintenanceRuleRepository(container: container)
            for rule in try fixtureRules() {
                try await ruleRepository.add(rule)
            }
            return AppDependencies(
                container: container, credentials: InMemoryCredentialsStore(),
                registrar: DisabledDeviceRegistrar(), reminderScheduler: RecordingReminderScheduler(),
                today: { UITestFixture.today },
                calendar: {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: UITestFixture.timeZoneIdentifier) ?? .gmt
                    return calendar
                })
        }

        private enum UITestingError: Error {
            case defaultsUnavailable
            case fixtureMismatch(UUID)
        }

        /// Записи фикстуры: количества по машинам — `UITestFixture.recordCounts`, особые записи — по `id`.
        private static func fixtureRecords() throws -> [(ServiceRecord, Data?)] {
            let day: TimeInterval = 86_400
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            func record(
                id: UUID = UUID(), _ vehicleID: Vehicle.ID, mileageKm: Int, type: ServiceType, dayOffset: Int
            ) throws -> ServiceRecord {
                try ServiceRecord(
                    id: id, vehicleID: vehicleID, date: start.addingTimeInterval(Double(dayOffset) * day),
                    mileageKm: mileageKm, serviceType: type, laborCost: Money(rubles: 1_500))
            }
            var result: [(ServiceRecord, Data?)] = []
            result.append(
                (
                    try record(
                        id: UITestFixture.recordToEdit, Vehicle.SampleID.landCruiser, mileageKm: 87_000,
                        type: .oilChange, dayOffset: 0), nil
                ))
            result.append(
                (
                    try record(
                        id: UITestFixture.recordWithReceipt, Vehicle.SampleID.transporter, mileageKm: 212_000,
                        type: .brakes, dayOffset: 1), receiptPNG()
                ))
            result.append(
                (
                    try record(
                        id: UITestFixture.recordToDelete, Vehicle.SampleID.transporter, mileageKm: 213_000,
                        type: .tires, dayOffset: 2), nil
                ))
            result.append(
                (
                    try record(
                        Vehicle.SampleID.transporter, mileageKm: 214_000, type: .filters, dayOffset: 3), nil
                ))
            for index in 0..<5 {
                result.append(
                    (
                        try record(
                            Vehicle.SampleID.cb500x, mileageKm: 15_000 + index * 800, type: .chain,
                            dayOffset: 10 + index), nil
                    ))
            }
            return result
        }

        /// Правила фикстуры: статусы при `UITestFixture.today` — просрочено, в норме, скоро (`UITestFixture.rule*`).
        private static func fixtureRules() throws -> [MaintenanceRule] {
            let today = UITestFixture.today
            return [
                try MaintenanceRule(
                    id: UITestFixture.ruleOverdue, vehicleID: Vehicle.SampleID.landCruiser, serviceType: .oilChange,
                    period: .months(12), distanceKm: 10_000, start: MaintenanceStart(date: today, mileageKm: 87_400)),
                try MaintenanceRule(
                    id: UITestFixture.ruleOK, vehicleID: Vehicle.SampleID.landCruiser, serviceType: .brakes,
                    period: nil, distanceKm: 50_000, start: MaintenanceStart(date: today, mileageKm: 87_400)),
                try MaintenanceRule(
                    id: UITestFixture.ruleSoon, vehicleID: Vehicle.SampleID.cb500x, serviceType: .inspection,
                    period: .months(12), distanceKm: nil,
                    start: MaintenanceStart(date: UITestFixture.ruleSoonStart, mileageKm: 18_250)),
            ]
        }

        /// PNG 1×1: достаточно, чтобы у записи был чек (скрепка и кнопка «Удалить фото»).
        private static func receiptPNG() -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
    }

    /// Пустое хранилище учётных данных в памяти: Keychain симулятора переживает переустановку,
    /// и токен из ручного прогона включил бы синхронизацию.
    private nonisolated final class InMemoryCredentialsStore: SyncCredentialsStore {
        private struct State {
            var token: String?
            var serverURL: URL?
        }
        private let state = Mutex(State())

        func readToken() -> String? { state.withLock { $0.token } }
        func saveToken(_ token: String) throws { state.withLock { $0.token = token } }
        func deleteToken() throws { state.withLock { $0.token = nil } }
        func readServerURL() -> URL? { state.withLock { $0.serverURL } }
        func saveServerURL(_ url: URL) { state.withLock { $0.serverURL = url } }
        func deleteServerURL() { state.withLock { $0.serverURL = nil } }
    }

    /// Планировщик уведомлений без системы: `notDetermined` → запрос сразу `authorized`, без системного алерта
    /// (выдать разрешение заранее нечем, проба 0.1); `replaceAll` запоминает набор.
    private nonisolated final class RecordingReminderScheduler: ReminderScheduling {
        private struct State {
            var status = ReminderAuthorization.notDetermined
            var reminders: [ScheduledReminder] = []
        }
        private let state = Mutex(State())

        func authorization() async -> ReminderAuthorization { state.withLock { $0.status } }

        func requestAuthorization() async -> ReminderAuthorization {
            state.withLock {
                if $0.status == .notDetermined { $0.status = .authorized }
                return $0.status
            }
        }

        func replaceAll(with reminders: [ScheduledReminder]) async throws {
            state.withLock { $0.reminders = reminders }
        }
    }

    /// Регистрация всегда падает как сетевой сбой: тестовый режим в сеть не ходит.
    private nonisolated struct DisabledDeviceRegistrar: DeviceRegistrar {
        func register(serverURL: URL, setupSecret: String, deviceName: String) async throws -> String {
            throw SyncFailure.network
        }
    }
#else
    extension AppDependencies {
        /// В Release тестового режима нет: аргумент запуска ничего не делает.
        static var launchBootstrap: () async throws -> AppDependencies { bootstrap }
    }
#endif
