import GarageCore
import XCTest

/// Таймаут ожидания элемента: симулятор на первом запуске медленный.
let uiTimeout: TimeInterval = 15

extension XCTestCase {
    /// Запускает приложение в тестовом режиме (SwiftData в памяти, свежая фикстура, без синхронизации).
    /// Язык для `LocalizedTextTests` передаётся в `extraArguments`.
    @MainActor
    func launchGarage(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [UITestFixture.launchArgument] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.buttons[AccessibilityID.VehicleList.add].waitForExistence(timeout: uiTimeout),
            "Список машин не появился")
        return app
    }
}

extension XCUIElement {
    /// Заменяет текст поля: тап, удаление текущего значения, ввод нового.
    @MainActor
    func replaceText(_ text: String) {
        tap()
        let current = (value as? String) ?? ""
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }
}

extension XCUIApplication {
    /// Строки машин в списке (кнопки с идентификатором-префиксом).
    var vehicleRows: XCUIElementQuery {
        buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.VehicleList.rowPrefix))
    }

    /// Ячейка списка, в которой лежит элемент: свайп делается по ячейке.
    func cell(containing element: XCUIElement) -> XCUIElement {
        cells.containing(.button, identifier: element.identifier).firstMatch
    }

    /// Подтверждает `confirmationDialog` кнопкой по идентификатору. Запасных путей нет: потерянный
    /// идентификатор должен ронять тест.
    @MainActor
    func confirmDialog(_ identifier: String) {
        // Идентификатор доходит до кнопки диалога, но в иерархии popover'а встречается дважды.
        let button = buttons.matching(identifier: identifier).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: uiTimeout), "Нет кнопки диалога \(identifier)")
        button.tap()
    }

    /// Прокручивает форму вверх, пока элемент не появится: ленивые ячейки `Form` вне экрана
    /// в иерархии отсутствуют.
    @MainActor
    func scrollUntilExists(_ element: XCUIElement, maxSwipes: Int = 5) {
        var swipes = 0
        while !element.exists && swipes < maxSwipes {
            swipeUp()
            swipes += 1
        }
    }

    /// Строка машины в списке.
    func vehicleRow(_ id: UUID) -> XCUIElement {
        buttons[AccessibilityID.VehicleList.row(id)]
    }

    /// Открывает экран машины из списка.
    @MainActor
    @discardableResult
    func openVehicle(_ id: UUID) -> XCUIElement {
        let row = vehicleRow(id)
        XCTAssertTrue(row.waitForExistence(timeout: uiTimeout), "Нет строки машины")
        row.tap()
        return buttons[AccessibilityID.VehicleDetail.more]
    }

    /// Свайп влево по строке и тап по кнопке действия.
    @MainActor
    func swipeDelete(_ row: XCUIElement, button identifier: String) {
        row.swipeLeft()
        let button = buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: uiTimeout), "Нет кнопки «Удалить» у строки")
        button.tap()
    }

    /// Закрывает `confirmationDialog` без выбора. Диалог на этой iOS — popover без кнопки отмены,
    /// его закрывает тап по системной области `PopoverDismissRegion` (от языка не зависит).
    @MainActor
    func dismissDialog() {
        let region = otherElements["PopoverDismissRegion"]
        // Без запасных путей: если диалог перестал быть popover'ом, тест должен упасть, а не нажать наугад.
        XCTAssertTrue(region.waitForExistence(timeout: uiTimeout), "Нет PopoverDismissRegion: диалог не popover?")
        region.tap()
    }

    /// Ждёт, пока число элементов запроса станет равным `count`.
    @MainActor
    func waitForCount(_ query: XCUIElementQuery, _ count: Int) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == %d", count), object: query)
        return XCTWaiter().wait(for: [expectation], timeout: uiTimeout) == .completed
    }

    /// Ждёт, пока `label` элемента начнётся с `prefix`.
    @MainActor
    func waitForLabel(_ element: XCUIElement, hasPrefix prefix: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", prefix), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: uiTimeout) == .completed
    }

    /// Ждёт, пока в `label` элемента появится `substring`.
    @MainActor
    func waitForLabel(_ element: XCUIElement, contains substring: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", substring), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: uiTimeout) == .completed
    }

    /// Ждёт, пока элемент исчезнет.
    @MainActor
    func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: uiTimeout) == .completed
    }
}
