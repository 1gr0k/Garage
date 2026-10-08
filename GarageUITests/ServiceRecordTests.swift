import GarageCore
import XCTest

/// Сценарии записей об обслуживании (регрессия B6 этапа 9). Замена фото через `PhotosPicker` сюда
/// не входит: на чистом симуляторе пикер недоступен, это визуальная проверка ui-checker'а.
final class ServiceRecordTests: XCTestCase {
    private typealias Detail = AccessibilityID.VehicleDetail
    private typealias Form = AccessibilityID.ServiceRecordForm

    @MainActor
    func testEditRecordMileageUpdatesRow() throws {
        let app = launchGarage()
        app.openVehicle(Vehicle.SampleID.landCruiser)

        let row = app.buttons[Detail.record(UITestFixture.recordToEdit)]
        XCTAssertTrue(row.waitForExistence(timeout: uiTimeout))
        row.tap()
        let mileage = app.textFields[Form.mileage]
        XCTAssertTrue(mileage.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(mileage.value as? String, "87000")
        mileage.replaceText("88000")
        app.buttons[Form.confirm].tap()
        XCTAssertTrue(app.waitForDisappearance(mileage), "Форма не закрылась")

        // Число — данные, а не перевод: ждём, пока строка обновится («88,000 km» / «88 000 км»), а затем
        // сравниваем цифры без разделителей, чтобы не зависеть от языка.
        XCTAssertTrue(app.waitForLabel(row, contains: "88"), "Строка записи не обновилась: \(row.label)")
        XCTAssertTrue(row.label.filter(\.isNumber).contains("88000"), "Строка записи: \(row.label)")
    }

    @MainActor
    func testRemoveReceiptPhoto() throws {
        let app = launchGarage()
        app.openVehicle(Vehicle.SampleID.transporter)

        let clip = app.descendants(matching: .any)[Detail.receiptClip(UITestFixture.recordWithReceipt)]
        XCTAssertTrue(clip.waitForExistence(timeout: uiTimeout), "У записи нет скрепки чека")
        app.buttons[Detail.record(UITestFixture.recordWithReceipt)].tap()
        let remove = app.buttons[Form.removePhoto]
        app.scrollUntilExists(remove)
        XCTAssertTrue(remove.waitForExistence(timeout: uiTimeout))
        remove.tap()
        XCTAssertTrue(app.buttons[Form.attachPhoto].waitForExistence(timeout: uiTimeout))
        app.buttons[Form.confirm].tap()
        XCTAssertTrue(app.waitForDisappearance(app.buttons[Form.attachPhoto]), "Форма не закрылась")

        XCTAssertTrue(app.waitForDisappearance(clip), "Скрепка осталась")
    }

    @MainActor
    func testSwipeDeleteRecordCancelThenConfirm() throws {
        let app = launchGarage()
        app.openVehicle(Vehicle.SampleID.transporter)
        let row = app.buttons[Detail.record(UITestFixture.recordToDelete)]
        XCTAssertTrue(row.waitForExistence(timeout: uiTimeout))

        app.swipeDelete(app.cell(containing: row), button: Detail.swipeDeleteRecord)
        app.dismissDialog()
        XCTAssertTrue(app.waitForDisappearance(app.popovers.firstMatch), "Диалог не закрылся")
        XCTAssertTrue(row.exists, "Отмена удалила запись")

        app.swipeDelete(app.cell(containing: row), button: Detail.swipeDeleteRecord)
        app.confirmDialog(Detail.confirmDeleteRecord)
        XCTAssertTrue(app.waitForDisappearance(row), "Запись не удалилась")
    }

    @MainActor
    func testDeleteRecordFromForm() throws {
        let app = launchGarage()
        app.openVehicle(Vehicle.SampleID.transporter)
        let row = app.buttons[Detail.record(UITestFixture.recordToDelete)]
        XCTAssertTrue(row.waitForExistence(timeout: uiTimeout))
        row.tap()

        let delete = app.buttons[Form.deleteRecord]
        XCTAssertTrue(delete.waitForExistence(timeout: uiTimeout))
        delete.tap()
        app.confirmDialog(Form.confirmDelete)

        XCTAssertTrue(app.waitForDisappearance(delete), "Форма не закрылась")
        XCTAssertTrue(app.waitForDisappearance(row), "Запись не удалилась")
    }
}
