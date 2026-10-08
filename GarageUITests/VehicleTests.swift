import GarageCore
import XCTest

/// Сценарии техники (регрессия B6 этапа 10). Элементы — только по идентификаторам.
final class VehicleTests: XCTestCase {
    private typealias List = AccessibilityID.VehicleList
    private typealias Detail = AccessibilityID.VehicleDetail
    private typealias Form = AccessibilityID.VehicleForm

    @MainActor
    func testAddVehicleShowsErrorsThenSaves() throws {
        let app = launchGarage()
        let rowsBefore = app.vehicleRows.count

        app.buttons[List.add].tap()
        let confirm = app.buttons[Form.confirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: uiTimeout))
        confirm.tap()
        XCTAssertTrue(app.staticTexts[Form.makeError].waitForExistence(timeout: uiTimeout))
        XCTAssertTrue(app.staticTexts[Form.modelError].exists)
        XCTAssertTrue(app.staticTexts[Form.yearError].exists)
        XCTAssertTrue(app.staticTexts[Form.mileageError].exists)

        app.textFields[Form.make].tap()
        app.textFields[Form.make].typeText("Skoda")
        app.textFields[Form.model].tap()
        app.textFields[Form.model].typeText("Octavia")
        app.textFields[Form.year].tap()
        app.textFields[Form.year].typeText("2018")
        app.textFields[Form.mileage].tap()
        app.textFields[Form.mileage].typeText("50000")
        confirm.tap()

        XCTAssertTrue(app.waitForDisappearance(app.textFields[Form.make]), "Форма не закрылась")
        XCTAssertTrue(app.waitForCount(app.vehicleRows, rowsBefore + 1), "Строк: \(app.vehicleRows.count)")
    }

    @MainActor
    func testEditVehicleYearUpdatesDetailAndList() throws {
        let app = launchGarage()
        let landCruiser = Vehicle.SampleID.landCruiser
        app.openVehicle(landCruiser)

        app.buttons[Detail.more].tap()
        app.buttons[Detail.edit].tap()
        let make = app.textFields[Form.make]
        XCTAssertTrue(make.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(make.value as? String, "Toyota")
        let year = app.textFields[Form.year]
        XCTAssertEqual(year.value as? String, "2019")
        year.replaceText("2020")
        app.buttons[Form.confirm].tap()
        XCTAssertTrue(app.waitForDisappearance(make), "Форма не закрылась")

        app.buttons["BackButton"].tap()
        let subtitle = app.descendants(matching: .any)[List.rowSubtitle(landCruiser)]
        XCTAssertTrue(subtitle.waitForExistence(timeout: uiTimeout))
        XCTAssertTrue(app.waitForLabel(subtitle, hasPrefix: "2020"), "Подзаголовок: \(subtitle.label)")
    }

    @MainActor
    func testSwipeDeleteCancelKeepsRowThenConfirmRemoves() throws {
        let app = launchGarage()
        let transporter = Vehicle.SampleID.transporter
        let row = app.vehicleRow(transporter)

        app.swipeDelete(app.cell(containing: row), button: List.swipeDelete)
        app.dismissDialog()
        XCTAssertTrue(app.waitForDisappearance(app.popovers.firstMatch), "Диалог не закрылся")
        XCTAssertTrue(row.exists, "Отмена удалила строку")

        app.swipeDelete(app.cell(containing: row), button: List.swipeDelete)
        app.confirmDialog(List.confirmDelete)
        XCTAssertTrue(app.waitForDisappearance(row), "Строка не удалилась")
    }

    @MainActor
    func testDeleteFromDetailReturnsToList() throws {
        let app = launchGarage()
        let cb500x = Vehicle.SampleID.cb500x
        app.openVehicle(cb500x)

        app.buttons[Detail.more].tap()
        app.buttons[Detail.deleteVehicle].tap()
        app.confirmDialog(Detail.confirmDeleteVehicle)

        XCTAssertFalse(
            app.descendants(matching: .any)[Detail.notFound].exists, "Мигнул «Vehicle Not Found»")
        XCTAssertTrue(app.buttons[List.add].waitForExistence(timeout: uiTimeout), "Нет списка")
        XCTAssertTrue(app.waitForDisappearance(app.vehicleRow(cb500x)), "Строка не удалилась")
    }
}
