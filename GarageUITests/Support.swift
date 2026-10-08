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

    /// Подтверждает `confirmationDialog`: кнопка по идентификатору, а если он не дошёл до popover'а —
    /// единственная кнопка диалога (от языка не зависит).
    @MainActor
    func confirmDialog(_ identifier: String) {
        // Идентификатор доходит до кнопки диалога, но в иерархии popover'а встречается дважды.
        let button = buttons.matching(identifier: identifier).firstMatch
        if button.waitForExistence(timeout: uiTimeout) {
            button.tap()
        } else {
            popovers.buttons.firstMatch.tap()
        }
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
        if region.waitForExistence(timeout: uiTimeout) {
            region.tap()
        } else if sheets.firstMatch.exists {
            // Если диалог всё же лист: кнопка отмены по роли, она последняя.
            sheets.firstMatch.buttons.allElementsBoundByIndex.last?.tap()
        }
    }

    /// Ждёт, пока элемент исчезнет.
    @MainActor
    func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: uiTimeout) == .completed
    }
}
