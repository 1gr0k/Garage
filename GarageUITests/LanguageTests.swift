import XCTest

/// Защита от ложно зелёного прогона: язык хоста — `ru-RU`, и если `-testLanguage` перестанет
/// действовать, все тесты молча пойдут на русском. Ожидаемый язык задаёт скрипт через
/// `TEST_RUNNER_GARAGE_EXPECTED_LANGUAGE` (xcodebuild снимает префикс). Без переменной тест падает.
final class LanguageTests: XCTestCase {
    /// Подпись кнопки `VehicleList.add` по языкам (литералы: это то, что увидит пользователь).
    private static let addButtonLabels = ["en": "Add Vehicle", "ru": "Добавить машину"]

    @MainActor
    func testRunsInExpectedLanguage() throws {
        let expected = try XCTUnwrap(
            ProcessInfo.processInfo.environment["GARAGE_EXPECTED_LANGUAGE"],
            "Не задан TEST_RUNNER_GARAGE_EXPECTED_LANGUAGE (en или ru): прогон без языка ничего не доказывает")
        let label = try XCTUnwrap(
            Self.addButtonLabels[expected], "Неизвестный ожидаемый язык «\(expected)»; ждём en или ru")
        let app = launchGarage()
        XCTAssertEqual(app.buttons[AccessibilityID.VehicleList.add].label, label)
    }
}
