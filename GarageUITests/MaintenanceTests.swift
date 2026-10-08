import GarageCore
import XCTest

/// Сценарии напоминаний о ТО (этап 12). «Сегодня» тестового режима фиксировано (`UITestFixture.today`), поэтому статусы
/// фикстуры не зависят от даты прогона. Статусы читаются из `accessibilityValue`, а не из текста каталога.
final class MaintenanceTests: XCTestCase {
    private typealias Detail = AccessibilityID.VehicleDetail
    private typealias Rules = AccessibilityID.MaintenanceRules
    private typealias Form = AccessibilityID.MaintenanceRuleForm

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Открывает экран напоминаний машины.
    @MainActor
    private func openRules(_ app: XCUIApplication, vehicle: UUID) {
        app.openVehicle(vehicle)
        let all = element(app, Detail.maintenanceAll)
        XCTAssertTrue(all.waitForExistence(timeout: uiTimeout), "Нет перехода к напоминаниям")
        all.tap()
        XCTAssertTrue(app.buttons[Rules.add].waitForExistence(timeout: uiTimeout), "Экран напоминаний не открылся")
    }

    /// Ждёт, пока `accessibilityValue` элемента станет равным `value`.
    @MainActor
    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: uiTimeout) == .completed
    }

    /// Переключатель `Form` надёжно нажимается у правого края, а не по центру строки (там подпись).
    @MainActor
    private func toggle(_ app: XCUIApplication, _ identifier: String) {
        let element = app.switches[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: uiTimeout), "Нет переключателя \(identifier)")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    @MainActor
    func testOverdueRuleIsShownOnVehicleScreenAndInList() throws {
        let app = launchGarage()
        app.openVehicle(Vehicle.SampleID.landCruiser)

        // Ближайшее по статусу — просроченное по дате масло, а не правило «в норме».
        let summary = element(app, Detail.maintenanceSummary)
        XCTAssertTrue(summary.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(summary.value as? String, "overdue")

        element(app, Detail.maintenanceAll).tap()
        let overdue = element(app, Rules.status(UITestFixture.ruleOverdue))
        XCTAssertTrue(overdue.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(overdue.value as? String, "overdue")
        // Положительный контроль: не всё подряд просрочено.
        XCTAssertEqual(element(app, Rules.status(UITestFixture.ruleOK)).value as? String, "ok")
    }

    @MainActor
    func testRuleDueWithinThirtyDaysIsDueSoon() throws {
        let app = launchGarage()
        app.openVehicle(Vehicle.SampleID.cb500x)

        let summary = element(app, Detail.maintenanceSummary)
        XCTAssertTrue(summary.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(summary.value as? String, "dueSoon")
    }

    @MainActor
    func testFirstRuleIsSavedWithoutSystemPermissionAlert() throws {
        let app = launchGarage()
        openRules(app, vehicle: Vehicle.SampleID.rockhopper)
        XCTAssertTrue(element(app, Rules.empty).exists, "У Rockhopper не должно быть правил")

        app.buttons[Rules.add].tap()
        let confirm = app.buttons[Form.confirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: uiTimeout))
        confirm.tap()
        XCTAssertTrue(app.waitForDisappearance(confirm), "Форма не закрылась")

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", Rules.rowPrefix))
        XCTAssertTrue(app.waitForCount(rows, 1), "Правило не появилось в списке")
        let status = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "maintenanceRules.status.")
        ).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(status.value as? String, "ok")

        // В тестовом режиме запрос разрешения идёт в фейк: системного алерта нет (запрос проверен в GarageTests).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertEqual(springboard.alerts.count, 0, "Появился системный алерт")
    }

    @MainActor
    func testFormWithoutIntervalShowsErrorAndStaysOpen() throws {
        let app = launchGarage()
        openRules(app, vehicle: Vehicle.SampleID.landCruiser)
        app.buttons[Rules.add].tap()

        toggle(app, Form.usesPeriod)
        app.buttons[Form.confirm].tap()

        XCTAssertTrue(element(app, Form.intervalError).waitForExistence(timeout: uiTimeout), "Нет ошибки интервала")
        XCTAssertTrue(app.buttons[Form.confirm].exists, "Форма закрылась")

        app.buttons[Form.close].tap()
        XCTAssertTrue(app.waitForDisappearance(app.buttons[Form.confirm]), "Форма не закрылась")
    }

    @MainActor
    func testEditRuleChangesItsStatus() throws {
        let app = launchGarage()
        openRules(app, vehicle: Vehicle.SampleID.landCruiser)
        let status = element(app, Rules.status(UITestFixture.ruleOverdue))
        XCTAssertTrue(status.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(status.value as? String, "overdue")

        app.buttons[Rules.row(UITestFixture.ruleOverdue)].tap()
        let period = app.textFields[Form.periodValue]
        XCTAssertTrue(period.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(period.value as? String, "12")
        // Поле выровнено вправо: тап по центру оставил бы курсор не в конце, и удаление символов не сработало бы.
        period.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        period.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "36")
        XCTAssertEqual(period.value as? String, "36")
        app.buttons[Form.confirm].tap()
        XCTAssertTrue(app.waitForDisappearance(period), "Форма не закрылась")

        XCTAssertTrue(waitForValue(status, "ok"), "Статус не обновился: \(status.value as? String ?? "nil")")
    }

    @MainActor
    func testDeleteRuleFromForm() throws {
        let app = launchGarage()
        openRules(app, vehicle: Vehicle.SampleID.landCruiser)
        let row = app.buttons[Rules.row(UITestFixture.ruleOK)]
        XCTAssertTrue(row.waitForExistence(timeout: uiTimeout))
        row.tap()

        let delete = app.buttons[Form.deleteRule]
        app.scrollUntilExists(delete)
        XCTAssertTrue(delete.waitForExistence(timeout: uiTimeout))
        delete.tap()
        app.confirmDialog(Form.confirmDelete)

        XCTAssertTrue(app.waitForDisappearance(delete), "Форма не закрылась")
        XCTAssertTrue(app.waitForDisappearance(row), "Правило не удалилось")
        XCTAssertTrue(app.buttons[Rules.row(UITestFixture.ruleOverdue)].exists, "Удалено лишнее правило")
    }

    @MainActor
    func testTurnOnNotificationsRowDisappearsAfterRequest() throws {
        let app = launchGarage()
        openRules(app, vehicle: Vehicle.SampleID.landCruiser)

        // Правила фикстуры «пришли» без запроса разрешения: фейк в `notDetermined`.
        let turnOn = app.buttons[Rules.enableNotifications]
        XCTAssertTrue(turnOn.waitForExistence(timeout: uiTimeout), "Нет строки «Включить уведомления»")
        turnOn.tap()

        XCTAssertTrue(app.waitForDisappearance(turnOn), "Строка осталась после запроса")
        XCTAssertFalse(element(app, Rules.notificationsOff).exists, "Появился баннер отказа")
    }

    @MainActor
    func testSwipeDeleteRuleCancelThenConfirm() throws {
        let app = launchGarage()
        openRules(app, vehicle: Vehicle.SampleID.landCruiser)
        let row = app.buttons[Rules.row(UITestFixture.ruleOK)]
        XCTAssertTrue(row.waitForExistence(timeout: uiTimeout))

        app.swipeDelete(app.cell(containing: row), button: Rules.swipeDelete)
        app.dismissDialog()
        XCTAssertTrue(app.waitForDisappearance(app.popovers.firstMatch), "Диалог не закрылся")
        XCTAssertTrue(row.exists, "Отмена удалила правило")

        app.swipeDelete(app.cell(containing: row), button: Rules.swipeDelete)
        app.confirmDialog(Rules.confirmDelete)
        XCTAssertTrue(app.waitForDisappearance(row), "Правило не удалилось")
        // Положительный контроль: второе правило машины осталось.
        XCTAssertTrue(app.buttons[Rules.row(UITestFixture.ruleOverdue)].exists)
    }
}
