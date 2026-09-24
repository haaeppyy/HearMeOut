import XCTest

/// Backend-configured UI tests against the LOCAL Supabase stack — the paths
/// the hermetic suites explicitly skip (staging session plumbing, real
/// lookup linkage, end-to-end sign-out).
///
/// Prerequisites (NOT run on every PR — nightly/pre-release only):
///   1. `supabase start` in backend/ (local stack on :54321)
///   2. functions served: `supabase functions serve --env-file supabase/.env`
///      (users-lookup must answer; the suite fast-fails otherwise)
///   3. Run via the UI-Staging plan (`-testPlan HearMeOut-UIStaging`).
///
/// Auth-UI paths (sign-up form, wrong-password/duplicate errors) are
/// DELIBERATELY absent: this simulator/XCUITest runtime delivers exactly
/// one keystroke per SecureField lifetime (focus never lands per AX, no
/// software keyboard, paste menu never appears — verified across a dozen
/// probes), so passwords cannot be typed here at all. Those paths stay
/// device-manual per docs/device-matrix.md. Tests below seed users via
/// REST and adopt the session through launch args instead, exercising
/// every real path downstream of auth.
///
/// Backend identities are unique per test (epoch-suffixed), so leftover
/// runs never collide. Each test wipes local state and launches
/// pre-onboarded — tests are order-independent.
final class BackendConfiguredUITests: XCTestCase {

    private static let stagingURL = "http://127.0.0.1:54321"
    /// Localhost-only publishable key: useless outside this machine's
    /// stack. Refresh via `supabase status` in backend/ if it ever rotates.
    private static let stagingKey = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - plumbing

    private struct SeededUser {
        let id: String
        let accessToken: String
        let refreshToken: String
        let phone: String
    }

    private func launchAs(_ user: SeededUser) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.hearmeout.app")
        app.launchArguments += [
            "--fresh-install-wipe",
            "--staging-url", Self.stagingURL,
            "--staging-key", Self.stagingKey,
            "--staging-session", user.accessToken,
            "--staging-refresh", user.refreshToken,
            "--staging-onboarded", "UITester", user.phone,
        ]
        app.launch()
        return app
    }

    /// Fast-fail with the fix (start the stack) instead of cryptic timeouts.
    /// Async (no semaphores): async XCTest methods don't run on the main
    /// thread, and blocking waits corrupt the waiter stack.
    private func requireLocalStack(file: StaticString = #filePath, line: UInt = #line) async {
        let url = URL(string: Self.stagingURL + "/rest/v1/")!
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue(Self.stagingKey, forHTTPHeaderField: "apikey")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "Local Supabase stack is not reachable at \(Self.stagingURL). Run `supabase start` in backend/ first.", file: file, line: line)
        } catch {
            XCTFail("Local Supabase stack is not reachable at \(Self.stagingURL): \(error). Run `supabase start` in backend/ first.", file: file, line: line)
        }
    }

    private func rest(
        method: String, path: String, token: String? = nil, body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: Self.stagingURL + path)!)
        request.httpMethod = method
        request.setValue(Self.stagingKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssert((response as? HTTPURLResponse)?.statusCode ?? 0 < 500, "REST \(method) \(path) failed")
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Seeds a backend user with a synced phone. The local stack mints the
    /// session flat (top-level access_token/refresh_token, no wrapper).
    private func seedUser(tag: String, phone: String) async throws -> SeededUser {
        let signup = try await rest(
            method: "POST", path: "/auth/v1/signup",
            body: ["email": "uitest-\(tag)@example.com", "password": "uitestpass123",
                   "data": ["display_name": "UI Test \(tag)"]]
        )
        let user = signup["user"] as? [String: Any]
        let session = signup["session"] as? [String: Any]
        let id = (user?["id"] as? String) ?? ""
        let access = (signup["access_token"] as? String) ?? (session?["access_token"] as? String) ?? ""
        let refresh = (signup["refresh_token"] as? String) ?? (session?["refresh_token"] as? String) ?? ""
        XCTAssertFalse(id.isEmpty, "seed signup returned no user: \(signup)")
        XCTAssertFalse(access.isEmpty, "seed signup returned no session — is GOTRUE_MAILER_AUTOCONFIRM on locally?")
        _ = try await rest(method: "PATCH", path: "/rest/v1/users?id=eq.\(id)", token: access, body: ["phone": phone])
        return SeededUser(id: id, accessToken: access, refreshToken: refresh, phone: phone)
    }

    private func uniquePhone() -> String {
        "+1555\(String(format: "%07d", Int(Date().timeIntervalSince1970) % 10_000_000))"
    }

    // MARK: - tests

    /// Staging redirect + session adoption land on Calls with tabs intact —
    /// a misconfigured URL/key or a broken adoption surfaces here, not on
    /// a device.
    @MainActor
    func testStagingSessionShowsCalls() async throws {
        await requireLocalStack()
        let tag = String(Int(Date().timeIntervalSince1970) % 100_000)
        let user = try await seedUser(tag: "calls-\(tag)", phone: uniquePhone())
        let app = launchAs(user)
        XCTAssertTrue(app.staticTexts["Calls"].waitForExistence(timeout: 20), "staging launch did not reach Calls")
        XCTAssertTrue(app.buttons["Contacts"].exists)
        XCTAssertTrue(app.buttons["Keypad"].exists)
    }

    /// Contact save resolves via users-lookup: a seeded phone reads
    /// "On Hear Me Out", an unknown number saves but reads "Not on Hear
    /// Me Out yet". The full backend linkage path, end to end in UI.
    @MainActor
    func testContactLookupHitAndMiss() async throws {
        await requireLocalStack()
        let tag = String(Int(Date().timeIntervalSince1970) % 100_000)
        let hitPhone = uniquePhone()
        try await seedUser(tag: "hit-\(tag)", phone: hitPhone)
        let missPhone = "+1999\(String(format: "%07d", (Int(Date().timeIntervalSince1970) + 1) % 10_000_000))"
        let user = try await seedUser(tag: "lookup-\(tag)", phone: uniquePhone())

        let app = launchAs(user)
        XCTAssertTrue(app.staticTexts["Calls"].waitForExistence(timeout: 20))

        app.buttons["Contacts"].tap()
        XCTAssertTrue(app.staticTexts["Contacts"].waitForExistence(timeout: 10))

        // Hit: seeded user's phone resolves → "On Hear Me Out".
        addContact(firstName: "Lookup Hit", phone: hitPhone)
        XCTAssertTrue(app.staticTexts["On Hear Me Out"].waitForExistence(timeout: 15), "lookup hit did not link")

        // Miss: unknown number saves but reads as not on the app.
        addContact(firstName: "Lookup Miss", phone: missPhone)
        XCTAssertTrue(app.staticTexts["Not on Hear Me Out yet"].waitForExistence(timeout: 15), "lookup miss not reflected")
    }

    /// Opens the sheet, waits for presentation to finish (tapping fields
    /// mid-animation fails AX scroll-to-visible), fills, saves, and joins
    /// on dismissal.
    private func addContact(firstName: String, phone: String) {
        let app = XCUIApplication(bundleIdentifier: "com.hearmeout.app")
        app.buttons["Add contact"].tap()
        XCTAssertTrue(app.staticTexts["New Contact"].waitForExistence(timeout: 10), "new-contact sheet did not open")
        app.textFields["First name"].tap()
        app.textFields["First name"].typeText(firstName)
        app.textFields["Phone"].tap()
        app.textFields["Phone"].typeText(phone)
        // PhonePad has no "+" key — if the plus didn't bind, normalization
        // (not lookup) is what breaks the hit. Fail here, not at linkage.
        XCTAssertEqual(app.textFields["Phone"].value as? String, phone, "phone did not bind (plus key?)")
        let saveButton = app.buttons["Save contact"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertTrue(saveButton.isEnabled, "Save still disabled with phone filled")
        saveButton.tap()
        let sheetGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.staticTexts["New Contact"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [sheetGone], timeout: 5), .completed, "save sheet did not dismiss")
    }

    /// Profile → Log Out clears the session and local profile and returns
    /// to onboarding — the repository-level sign-out regression, end to end.
    @MainActor
    func testSignOutReturnsToOnboarding() async throws {
        await requireLocalStack()
        let tag = String(Int(Date().timeIntervalSince1970) % 100_000)
        let user = try await seedUser(tag: "signout-\(tag)", phone: uniquePhone())
        let app = launchAs(user)
        XCTAssertTrue(app.staticTexts["Calls"].waitForExistence(timeout: 20))

        app.buttons["Profile"].tap()
        let logOut = app.buttons["Log Out"]
        XCTAssertTrue(logOut.waitForExistence(timeout: 10))
        logOut.tap()
        XCTAssertTrue(
            app.staticTexts["Let’s get to know you"].waitForExistence(timeout: 10),
            "sign-out did not return to onboarding"
        )
    }
}
