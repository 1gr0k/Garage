import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunches() throws {
        let app = launchGarage()
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testSyncSettingsCloseButtonDismissesSheet() throws {
        let app = launchGarage()
        app.buttons[AccessibilityID.VehicleList.sync].tap()
        let close = app.buttons[AccessibilityID.SyncSettings.close]
        XCTAssertTrue(close.waitForExistence(timeout: uiTimeout), "Нет кнопки закрытия настроек синхронизации")
        close.tap()
        XCTAssertTrue(app.buttons[AccessibilityID.VehicleList.add].waitForExistence(timeout: uiTimeout))
        XCTAssertFalse(close.exists)
    }
}
