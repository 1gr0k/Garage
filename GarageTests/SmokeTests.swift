import Testing

@testable import Garage

/// Проверяет, что таргет собирается, запускается в хосте `Garage.app` и видит модуль приложения.
@Test func testTargetRunsInsideHostApp() {
    #expect(Bool(true))
}
