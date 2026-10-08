import GarageCore
import XCTest

/// Проверки ru-текстов, которые уже ломались: склонения записей и год без разделителей тысяч.
/// Язык задан явно аргументами запуска и от `-testLanguage` не зависит. Идёт только в ru-проходе
/// (en-проход вызывается с `-skip-testing:GarageUITests/LocalizedTextTests`). Ожидаемые строки —
/// литералы ru: это то, что увидит пользователь.
final class LocalizedTextTests: XCTestCase {
    private typealias List = AccessibilityID.VehicleList

    @MainActor
    private func launchRussian() -> XCUIApplication {
        launchGarage(extraArguments: ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"])
    }

    @MainActor
    private func subtitle(_ app: XCUIApplication, _ id: UUID) -> String {
        let element = app.descendants(matching: .any)[List.rowSubtitle(id)]
        XCTAssertTrue(element.waitForExistence(timeout: uiTimeout))
        return element.label
    }

    /// Подпись `HStack` склеивается из двух текстов через запятую: «2019 · , 1 запись».
    @MainActor
    func testRecordCountPluralsInList() throws {
        let app = launchRussian()
        let expected: [(UUID, String)] = [
            (Vehicle.SampleID.landCruiser, "1 запись"),
            (Vehicle.SampleID.transporter, "3 записи"),
            (Vehicle.SampleID.cb500x, "5 записей"),
            (Vehicle.SampleID.rockhopper, "0 записей"),
        ]
        for (id, count) in expected {
            XCTAssertTrue(subtitle(app, id).hasSuffix(count), "«\(subtitle(app, id))» должно кончаться на «\(count)»")
        }
    }

    @MainActor
    func testVehicleDeletionDialogPlural() throws {
        let app = launchRussian()
        let expected: [(UUID, String)] = [
            (Vehicle.SampleID.transporter, "Вместе с ней будут удалены 3 записи. Это нельзя отменить."),
            (Vehicle.SampleID.cb500x, "Вместе с ней будут удалены 5 записей. Это нельзя отменить."),
        ]
        for (id, message) in expected {
            let row = app.vehicleRow(id)
            app.swipeDelete(app.cell(containing: row), button: List.swipeDelete)
            XCTAssertTrue(
                app.staticTexts[message].waitForExistence(timeout: uiTimeout),
                "В диалоге нет текста «\(message)»")
            app.dismissDialog()
            XCTAssertTrue(app.waitForDisappearance(app.popovers.firstMatch))
        }
    }

    @MainActor
    func testYearHasNoThousandsSeparator() throws {
        let app = launchRussian()
        let year = subtitle(app, Vehicle.SampleID.landCruiser)
        XCTAssertTrue(year.hasPrefix("2019"), "Подзаголовок: \(year)")
        for separated in ["2 019", "2\u{00A0}019", "2\u{202F}019", "2,019"] {
            XCTAssertFalse(year.contains(separated), "Год с разделителем в «\(year)»")
        }

        // Поле года в правке — тоже без разделителя.
        app.openVehicle(Vehicle.SampleID.landCruiser)
        app.buttons[AccessibilityID.VehicleDetail.more].tap()
        app.buttons[AccessibilityID.VehicleDetail.edit].tap()
        let field = app.textFields[AccessibilityID.VehicleForm.year]
        XCTAssertTrue(field.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(field.value as? String, "2019")

        // Ошибка диапазона: годы без разделителей («от 1900 до 2027»).
        field.replaceText("1800")
        app.buttons[AccessibilityID.VehicleForm.confirm].tap()
        let upper = Calendar.current.component(.year, from: Date()) + 1
        let error = app.staticTexts[AccessibilityID.VehicleForm.yearError]
        XCTAssertTrue(error.waitForExistence(timeout: uiTimeout))
        XCTAssertEqual(error.label, "Введите год от 1900 до \(upper)")
    }
}
