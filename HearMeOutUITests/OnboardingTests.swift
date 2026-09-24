import XCTest

/// App flows under `--uitest-local-backend-off` (hermetic: no network).
/// Fresh simulator = empty GRDB + fresh UserDefaults, so onboarding runs.
final class OnboardingTests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.hearmeout.app")
        app.launchArguments += ["--uitest-local-backend-off", "--fresh-install-wipe"]
        app.launch()
        return app
    }

    func testOnboardingCompletesToCalls() {
        let app = launch()

        // Gate: Continue disabled with empty fields.
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        XCTAssertFalse(continueButton.isEnabled)

        // Fill name + phone.
        app.textFields["Your name"].tap()
        app.textFields["Your name"].typeText("UI Tester")
        app.textFields["+91 98765 43210"].tap()
        app.textFields["+91 98765 43210"].typeText("5550001234")

        // Still gated: no profile selected.
        XCTAssertFalse(continueButton.isEnabled)

        // Pick the text-first profile, then continue.
        app.buttons["I can’t hear or speak"].tap()
        XCTAssertTrue(continueButton.isEnabled)
        continueButton.tap()

        // Lands on Calls with the Text Mode default.
        XCTAssertTrue(app.staticTexts["Calls"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Text Mode'")).firstMatch.exists)
    }
}
