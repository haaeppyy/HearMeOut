import XCTest

/// Tab navigation + local-mode keypad dial (free-dial: backend forced off,
/// so the call button enables for any typed number and presents the
/// simulated audio cover, which dismisses via End).
final class TabsAndKeypadTests: XCTestCase {

    private func launchPastOnboarding() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.hearmeout.app")
        app.launchArguments += ["--uitest-local-backend-off", "--fresh-install-wipe"]
        app.launch()

        app.textFields["Your name"].tap()
        app.textFields["Your name"].typeText("UI Tester")
        app.textFields["+91 98765 43210"].tap()
        app.textFields["+91 98765 43210"].typeText("5550001234")
        app.buttons["I can hear & speak"].tap()
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Calls"].waitForExistence(timeout: 10))
        return app
    }

    func testTabsExist() {
        let app = launchPastOnboarding()
        XCTAssertTrue(app.buttons["Contacts"].exists)
        XCTAssertTrue(app.buttons["Keypad"].exists)
        XCTAssertTrue(app.buttons["Calls"].exists)
    }

    func testLocalKeypadDialPresentsAudioCall() {
        let app = launchPastOnboarding()
        app.buttons["Keypad"].tap()

        // Dial 5-5-5 and place the call.
        for _ in 0..<3 { app.buttons["5"].tap() }
        let callButton = app.buttons["Call"]
        XCTAssertTrue(callButton.waitForExistence(timeout: 5))
        XCTAssertTrue(callButton.isEnabled)
        callButton.tap()

        // Simulated audio cover appears (connecting → timer), End dismisses.
        XCTAssertTrue(app.buttons["End"].waitForExistence(timeout: 10))
        app.buttons["End"].tap()

        // Back on Calls with one history row written.
        XCTAssertTrue(app.staticTexts["Calls"].waitForExistence(timeout: 10))
    }
}
