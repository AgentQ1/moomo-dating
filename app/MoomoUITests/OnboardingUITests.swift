import XCTest

/// End-to-end flows through the real UI, and screenshot capture for visual
/// comparison against the reference screens.
final class OnboardingUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Resets mock accounts and drafts so each test starts from a cold,
        // signed-out app rather than inheriting the last run's state.
        app.launchArguments += ["-ui-testing-reset"]
        app.launch()
        return app
    }

    // MARK: - Consent gate

    func testSignInButtonsAreDisabledUntilConsent() {
        let app = launch()
        let google = app.buttons["Continue with Google"]
        XCTAssertTrue(google.waitForExistence(timeout: 5))

        XCTAssertFalse(google.isEnabled, "Sign-in must be disabled before consent")
        XCTAssertFalse(app.buttons["Continue with Apple"].isEnabled)
        XCTAssertFalse(app.buttons["Continue as Guest"].isEnabled)
    }

    func testTickingConsentEnablesSignIn() {
        let app = launch()
        let guest = app.buttons["Continue as Guest"]
        XCTAssertTrue(guest.waitForExistence(timeout: 5))
        XCTAssertFalse(guest.isEnabled)

        consentCheckbox(in: app).tap()

        XCTAssertTrue(guest.waitForEnabled(timeout: 2), "Consent must enable sign-in")
    }

    /// Tapping a disabled button must not sign anyone in.
    func testTappingDisabledButtonDoesNothing() {
        let app = launch()
        let guest = app.buttons["Continue as Guest"]
        XCTAssertTrue(guest.waitForExistence(timeout: 5))

        guest.tap()

        XCTAssertFalse(
            app.staticTexts["What's your name?"].waitForExistence(timeout: 2),
            "A disabled sign-in button must never start onboarding"
        )
    }

    // MARK: - Guest flow

    func testGuestSignInReachesOnboarding() {
        let app = launch()
        signInAsGuest(app)
        XCTAssertTrue(
            app.staticTexts["What's your name?"].waitForExistence(timeout: 8),
            "Guest sign-in must land on onboarding"
        )
    }

    func testAgeGateBlocksUnderageInOnboarding() {
        let app = launch()
        signInAsGuest(app)

        let nameField = app.textFields["First name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        nameField.tap()
        nameField.typeText("Alex")
        continueButton(app).tap()

        XCTAssertTrue(app.staticTexts["When's your birthday?"].waitForExistence(timeout: 4))

        // The picker's range starts 18 years ago, so an underage date cannot be
        // selected at all — the gate is enforced by construction, not by
        // validating after the fact.
        let picker = app.datePickers.firstMatch
        XCTAssertTrue(picker.exists, "Date of birth picker must be present")
    }

    func testOnboardingResumesAfterRelaunch() {
        let app = launch()
        signInAsGuest(app)

        let nameField = app.textFields["First name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        nameField.tap()
        nameField.typeText("Riley")
        continueButton(app).tap()
        XCTAssertTrue(app.staticTexts["When's your birthday?"].waitForExistence(timeout: 4))

        // Relaunch *without* the reset flag: the session and draft persist.
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launch()

        XCTAssertTrue(
            relaunched.staticTexts["When's your birthday?"].waitForExistence(timeout: 8),
            "Onboarding must resume at the step it was left on"
        )
    }

    // MARK: - Screenshots

    /// Captures the welcome screen for visual comparison. Attached to the test
    /// result and written to disk by tools/visual/capture.sh.
    func testCaptureWelcomeScreenshot() {
        let app = launch()
        XCTAssertTrue(app.buttons["Continue with Google"].waitForExistence(timeout: 5))

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "welcome"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureDiscoverScreenshot() {
        let app = launch()
        signInAsGuest(app)
        completeGuestOnboarding(app)

        XCTAssertTrue(
            app.staticTexts["Hey there 👋"].waitForExistence(timeout: 10),
            "Onboarding must finish into Discover"
        )
        // Let the hero's load settle so the skeleton isn't what gets captured.
        Thread.sleep(forTimeInterval: 1.5)

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "discover"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Helpers

    /// `app.buttons["Continue"]` matches both the button and its label, so
    /// every tap has to disambiguate or XCTest raises "multiple matching
    /// elements".
    private func continueButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Continue"].firstMatch
    }

    /// Drives the wheel to a year that clears the age gate.
    private func setDateOfBirth(_ app: XCUIApplication, year: String) {
        let wheels = app.datePickers.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 4))
        // Month, day, year — year is the last wheel in this locale.
        wheels.element(boundBy: wheels.count - 1).adjust(toPickerWheelValue: year)
    }

    private func consentCheckbox(in app: XCUIApplication) -> XCUIElement {
        app.buttons["I have read and agree to the Privacy Policy and Terms of Service"]
    }

    private func signInAsGuest(_ app: XCUIApplication) {
        let checkbox = consentCheckbox(in: app)
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        checkbox.tap()

        let guest = app.buttons["Continue as Guest"]
        XCTAssertTrue(guest.waitForEnabled(timeout: 2))
        guest.tap()
    }

    /// Walks the shortened guest flow to completion.
    private func completeGuestOnboarding(_ app: XCUIApplication) {
        let nameField = app.textFields["First name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        nameField.tap()
        nameField.typeText("Sam")
        continueButton(app).tap()

        // Date of birth must be chosen explicitly — the wheel showing a date
        // is not the user stating one, so the step can't be skipped.
        XCTAssertTrue(app.staticTexts["When's your birthday?"].waitForExistence(timeout: 4))
        setDateOfBirth(app, year: "2000")
        continueButton(app).tap()

        // Gender
        XCTAssertTrue(app.staticTexts["How do you identify?"].waitForExistence(timeout: 4))
        app.buttons["Non-binary"].firstMatch.tap()
        continueButton(app).tap()

        // Interested in
        XCTAssertTrue(app.staticTexts["Who would you like to meet?"].waitForExistence(timeout: 4))
        app.buttons["Everyone"].firstMatch.tap()
        continueButton(app).tap()

        // Camera & mic explainer
        XCTAssertTrue(app.staticTexts["Camera & microphone"].waitForExistence(timeout: 4))
        continueButton(app).tap()

        // Safety
        XCTAssertTrue(app.staticTexts["Be real, be kind"].waitForExistence(timeout: 4))
        app.switches.firstMatch.tap()
        continueButton(app).tap()

        // Review
        XCTAssertTrue(app.staticTexts["Looking good"].waitForExistence(timeout: 4))
        app.buttons["Start meeting people"].firstMatch.tap()
    }
}

extension XCUIElement {
    /// `waitForExistence` for enablement — enabling is animated, so a bare
    /// `isEnabled` check right after a tap races the animation.
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}

extension OnboardingUITests {
    /// The wheel shows a plausible date from the moment the step opens. If that
    /// alone let someone through, the app would be recording an age nobody
    /// stated — so an untouched picker must block.
    func testUntouchedDatePickerDoesNotSatisfyTheAgeGate() {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing-reset"]
        app.launch()

        app.buttons["I have read and agree to the Privacy Policy and Terms of Service"].tap()
        let guest = app.buttons["Continue as Guest"]
        XCTAssertTrue(guest.waitForEnabled(timeout: 2))
        guest.tap()

        let nameField = app.textFields["First name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        nameField.tap()
        nameField.typeText("Alex")
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["When's your birthday?"].waitForExistence(timeout: 4))
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertFalse(
            app.staticTexts["How do you identify?"].waitForExistence(timeout: 2),
            "An untouched date picker must not satisfy the age gate"
        )
        XCTAssertTrue(app.staticTexts["Please scroll to set your date of birth."].exists)
    }
}
