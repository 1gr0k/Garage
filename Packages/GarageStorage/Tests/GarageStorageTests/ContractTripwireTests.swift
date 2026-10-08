import GarageAPI
import Testing

@testable import GarageStorage

/// Тест-растяжка (docs/api.md, «Правила эволюции контракта», п. 4–5; docs/plans/stage-12-reminders.md, решение 9d):
/// какие виды сущностей знал клиент при каждой `GarageStore.schemaVersion`.
///
/// Новый вид сущности без роста версии оставил бы устройства, уже пропустившие эти сущности (`PullResponse.skipped`),
/// без них навсегда: рост версии сбрасывает курсор, и следующая синхронизация скачивает всё заново.
///
/// Строки прошлых версий заморожены: правка снимка существующей версии вместо роста версии — тот же обход растяжки.
private let knownEntityKinds: [Int: [String]] = [
    2: ["vehicle", "serviceRecord"],
    3: ["vehicle", "serviceRecord", "maintenanceRule"],
    4: ["vehicle", "serviceRecord", "maintenanceRule"],
]

private let hint =
    "Изменился набор EntityKind: увеличь GarageStore.schemaVersion и добавь снимок для новой версии в "
    + "knownEntityKinds (docs/api.md, «Правила эволюции контракта», п. 4–5)"

@Suite struct ContractTripwireTests {
    @Test func entityKindsMatchTheSnapshotOfTheCurrentSchemaVersion() {
        guard let snapshot = knownEntityKinds[GarageStore.schemaVersion] else {
            Issue.record(
                "Нет снимка knownEntityKinds для schemaVersion \(GarageStore.schemaVersion). \(hint)")
            return
        }
        let current = EntityKind.allCases.map(\.rawValue)
        // Порядок case'ов не важен: сравниваем наборы.
        #expect(Set(snapshot) == Set(current), "\(hint). Снимок: \(snapshot), сейчас: \(current)")
    }

    /// Снимок текущей версии существует отдельным кейсом: забытая строка в таблице даёт то же сообщение, но
    /// не маскируется под «набор изменился».
    @Test func snapshotExistsForTheCurrentSchemaVersion() {
        #expect(
            knownEntityKinds[GarageStore.schemaVersion] != nil,
            "Нет снимка knownEntityKinds для schemaVersion \(GarageStore.schemaVersion). \(hint)")
    }

    /// Виды не убирают: клиент старой версии мог их сохранить, и сервер их хранит.
    @Test func snapshotsOnlyGrow() {
        let versions = knownEntityKinds.keys.sorted()
        for (older, newer) in zip(versions, versions.dropFirst()) {
            let removed = Set(knownEntityKinds[older] ?? []).subtracting(knownEntityKinds[newer] ?? [])
            #expect(removed.isEmpty, "Версия \(newer) потеряла виды \(removed) относительно версии \(older)")
        }
    }
}
