import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunches() throws {
        let app = launchGarage()
        XCTAssertEqual(app.state, .runningForeground)
    }
}
