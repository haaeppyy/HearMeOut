import XCTest
@testable import HearMeOut

final class HearMeOutUITests: XCTestCase {
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssert(app.wait(for: .running, timeout: 5))
    }
}
