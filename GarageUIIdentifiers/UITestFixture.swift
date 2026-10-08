#if DEBUG
    import Foundation
    import GarageCore

    /// Тестовый режим запуска: аргумент и описание фикстуры, общие для приложения и `GarageUITests`.
    /// Сами записи фикстуры собирает `AppDependencies+UITesting.swift`; тестам нужны только ожидаемые
    /// количества и идентификаторы записей.
    nonisolated enum UITestFixture {
        /// Аргумент запуска, который включает тестовый режим (только Debug).
        static let launchArgument = "-GarageUITesting"

        /// Сколько записей у каждой демо-машины (для склонений one/few/many и нуля).
        static let recordCounts: [UUID: Int] = [
            Vehicle.SampleID.landCruiser: 1,
            Vehicle.SampleID.transporter: 3,
            Vehicle.SampleID.cb500x: 5,
            Vehicle.SampleID.rockhopper: 0,
        ]

        /// Фиксированное «сегодня» тестового режима (2025-06-01 12:00 UTC): статусы напоминаний не зависят от даты прогона.
        static let today = Date(timeIntervalSince1970: 1_748_779_200)
        /// Часовой пояс календаря тестового режима.
        static let timeZoneIdentifier = "UTC"

        /// Запись Land Cruiser для правки пробега.
        static let recordToEdit = UUID(uuidString: "5A3F1000-6C0D-4B7E-9A10-000000000001")!
        /// Запись Transporter с фото чека.
        static let recordWithReceipt = UUID(uuidString: "5A3F1000-6C0D-4B7E-9A10-000000000002")!
        /// Запись Transporter для сценариев удаления.
        static let recordToDelete = UUID(uuidString: "5A3F1000-6C0D-4B7E-9A10-000000000003")!
    }
#endif
