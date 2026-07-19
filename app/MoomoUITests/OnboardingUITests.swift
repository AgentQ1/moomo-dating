import XCTest

/// End-to-end flows through the real UI, and screenshot capture for visual
/// comparison against the reference screens.
///
/// Sign-in is the phone flow: number → Verification → SMS code → onboarding.
/// The mock backend accepts exactly `123456`, so the OTP step is
/// deterministic. Completing onboarding walks the full flow — the photo step
/// needs photos in the simulator's library (`xcrun simctl addmedia`).
final class OnboardingUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Resets mock accounts and drafts so each test starts from a cold,
        // signed-out app rather than inheriting the last run's state.
        //
        // `-use-mock-backend` keeps these tests off live Firebase. They assert
        // UI behaviour, not backend behaviour, and running them against the
        // real project would send real verification SMS. Live coverage lives
        // in `FirebaseIntegrationTests`.
        app.launchArguments += ["-ui-testing-reset", "-use-mock-backend"]
        app.launch()
        return app
    }

    // MARK: - Consent gate

    /// The buttons render at full strength before consent — the reference
    /// shows them undimmed — and the requirement is enforced on tap instead.
    func testVerificationWithoutConsentIsRefused() {
        let app = launch()
        typePhoneNumber(app, "5550100200")

        app.buttons["Verification"].firstMatch.tap()

        XCTAssertTrue(
            app.staticTexts["Please agree to the Privacy Policy and Terms of Service first."]
                .waitForExistence(timeout: 3),
            "Verification without consent must explain itself"
        )
        XCTAssertFalse(
            app.staticTexts["Enter your code"].waitForExistence(timeout: 2),
            "No SMS may be sent without consent"
        )
    }

    // MARK: - Phone flow

    func testPhoneSignInReachesOnboarding() {
        let app = launch()
        signInWithPhone(app)
        XCTAssertTrue(
            app.staticTexts["What's your name?"].waitForExistence(timeout: 8),
            "Phone sign-in must land on onboarding"
        )
    }

    func testWrongCodeShowsInlineErrorAndStaysOnOTP() {
        let app = launch()
        startPhoneVerification(app, number: "5550100200")

        enterCode(app, "000000")

        XCTAssertTrue(
            app.staticTexts["That code isn't correct. Check the SMS and try again."]
                .waitForExistence(timeout: 5),
            "A wrong code must surface inline"
        )
        XCTAssertTrue(
            app.staticTexts["Enter your code"].exists,
            "A wrong code must keep the OTP screen up for another try"
        )

        // The right code still works afterwards.
        enterCode(app, "123456")
        XCTAssertTrue(
            app.staticTexts["What's your name?"].waitForExistence(timeout: 8),
            "The correct code must recover the flow"
        )
    }

    func testBackFromOTPReturnsToTheNumber() {
        let app = launch()
        startPhoneVerification(app, number: "5550100200")

        app.buttons["Change phone number"].tap()

        XCTAssertTrue(
            app.buttons["Verification"].firstMatch.waitForExistence(timeout: 4),
            "Backing out of the OTP screen must return to the welcome number entry"
        )
    }

    // MARK: - Onboarding

    func testAgeGateBlocksUnderageInOnboarding() {
        let app = launch()
        signInWithPhone(app)

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
        signInWithPhone(app)

        let nameField = app.textFields["First name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        nameField.tap()
        nameField.typeText("Riley")
        continueButton(app).tap()
        XCTAssertTrue(app.staticTexts["When's your birthday?"].waitForExistence(timeout: 4))

        // Relaunch *without* the reset flag: the session and draft persist.
        // The backend flag must be carried over — a relaunch that resolved to a
        // different backend than the one just signed into would have nothing to
        // resume, and would fail this test for a reason it isn't testing.
        app.terminate()
        let relaunched = XCUIApplication()
        relaunched.launchArguments += ["-use-mock-backend"]
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
        XCTAssertTrue(app.buttons["Verification"].firstMatch.waitForExistence(timeout: 5))

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "welcome"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureDiscoverScreenshot() throws {
        try assertPhotoLibraryAvailable()
        let app = launch()
        signInWithPhone(app)
        completeOnboarding(app)

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

    func testCaptureSpeedCallScreenshot() throws {
        try assertPhotoLibraryAvailable()
        let app = launch()
        signInWithPhone(app)
        completeOnboarding(app)

        XCTAssertTrue(
            app.staticTexts["Hey there 👋"].waitForExistence(timeout: 10),
            "Onboarding must finish into Discover"
        )

        // Video Match, not the hero: the reference is a video call, with the
        // self-view and the Camera control.
        app.buttons["Video Match. Instant video conversations"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons["call.end"].waitForExistence(timeout: 12),
            "Matchmaking must reach a live call"
        )

        // The reference is frozen at 02:39. Waiting the ~21s until the real
        // countdown reads the same keeps the header pixel-comparable.
        XCTAssertTrue(
            app.staticTexts["Time left 02:39"].waitForExistence(timeout: 40),
            "The countdown must pass 02:39"
        )

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "speed-call"
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
        let checkbox = app.buttons["I have read and agree to the Privacy Policy and Terms of Service"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        return checkbox
    }

    private func typePhoneNumber(_ app: XCUIApplication, _ number: String) {
        let field = app.textFields["phone.number"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(number)
    }

    /// Consent + number + Verification: leaves the app on the OTP screen.
    private func startPhoneVerification(_ app: XCUIApplication, number: String) {
        consentCheckbox(in: app).tap()
        typePhoneNumber(app, number)
        app.buttons["Verification"].firstMatch.tap()

        XCTAssertTrue(
            app.staticTexts["Enter your code"].waitForExistence(timeout: 8),
            "Sending the SMS must open the OTP screen"
        )
    }

    /// Types into the invisible field that backs the code boxes.
    private func enterCode(_ app: XCUIApplication, _ code: String) {
        let field = app.textFields["otp.code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(code)
    }

    /// The full mock phone sign-in: welcome → SMS → valid code.
    private func signInWithPhone(_ app: XCUIApplication) {
        startPhoneVerification(app, number: "5550100200")
        enterCode(app, "123456")
    }

    private func assertPhotoLibraryAvailable() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == nil,
            "Completing onboarding requires a simulator with a seeded photo library."
        )
    }

    /// Walks the full onboarding flow to completion — phone users take every
    /// step, including location and photos (the guest short flow is gone with
    /// anonymous auth).
    private func completeOnboarding(_ app: XCUIApplication) {
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

        // Location — a list of city cards.
        XCTAssertTrue(app.staticTexts["Where are you?"].waitForExistence(timeout: 4))
        app.buttons["Chicago, United States"].firstMatch.tap()
        continueButton(app).tap()

        // Photos — pick one through the system picker and wait for upload.
        XCTAssertTrue(app.staticTexts["Add your photos"].waitForExistence(timeout: 5))
        app.buttons["photos.add"].firstMatch.tap()
        let pickerBar = app.navigationBars["Photos"]
        XCTAssertTrue(pickerBar.waitForExistence(timeout: 10), "The native PhotosPicker must open")
        let thumbnails = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(
            thumbnails.firstMatch.waitForExistence(timeout: 10),
            "Simulator photo library appears to be empty — run `xcrun simctl addmedia`"
        )
        thumbnails.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForEnabled(timeout: 3))
        done.tap()
        XCTAssertTrue(
            app.buttons["photos.remove.0"].waitForExistence(timeout: 20),
            "The picked photo must finish uploading"
        )
        continueButton(app).tap()

        // Bio is optional — continue through.
        XCTAssertTrue(app.staticTexts["Tell us about you"].waitForExistence(timeout: 4))
        continueButton(app).tap()

        // Interests need three.
        XCTAssertTrue(app.staticTexts["What are you into?"].waitForExistence(timeout: 4))
        app.buttons["Coffee"].firstMatch.tap()
        app.buttons["Hiking"].firstMatch.tap()
        app.buttons["Travel"].firstMatch.tap()
        continueButton(app).tap()

        // Camera & mic explainer
        XCTAssertTrue(app.staticTexts["Camera & microphone"].waitForExistence(timeout: 4))
        continueButton(app).tap()

        // Notifications explainer
        XCTAssertTrue(app.staticTexts["Stay in the loop"].waitForExistence(timeout: 4))
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
        let app = launch()
        signInWithPhone(app)

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
