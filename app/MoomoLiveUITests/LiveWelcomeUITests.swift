import XCTest

/// Drives the **real Moomo app** against the **real `moomo-c7a37` project**.
///
/// Separate target from `MoomoUITests` on purpose. That suite forces
/// `-use-mock-backend` and must stay deterministic and offline; this one
/// deliberately omits the flag, so `BackendConfiguration` resolves to
/// `.firebase` and the app talks to live Firebase.
///
/// Anonymous auth is gone, and completing a live sign-in now requires either
/// a real OAuth identity or a real SMS — neither of which an automated run
/// may mint against production. (Firebase's console-configured *test phone
/// numbers* would make the OTP flow drivable here; none are configured, and
/// configuring one is a console change this repo doesn't own.) So this suite
/// asserts the live app's resting states instead: welcome renders with the
/// phone flow, and a cold relaunch never hangs or strands.
///
///     xcodebuild test -project Moomo.xcodeproj -scheme MoomoLiveUI \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
final class LiveWelcomeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches the real app against live Firebase.
    /// - Parameter reset: clears local drafts. Never clears the Firebase
    ///   session — that is the keychain, and a relaunch must find it.
    private func launchLive(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        // Note what is NOT here: `-use-mock-backend`. That absence is the whole
        // point of this target.
        app.launchArguments = reset ? ["-ui-testing-reset"] : []
        app.launch()
        return app
    }

    /// The banner only appears in mock mode. Its absence is the app telling us,
    /// through its own UI, that it is on real Firebase — so this guards against
    /// the test silently passing against a mock.
    private func assertOnRealFirebase(_ app: XCUIApplication, _ message: String) {
        let banner = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'LOCAL MOCK MODE'")
        ).firstMatch
        XCTAssertFalse(
            banner.exists,
            "\(message): app is in mock mode, so this proves nothing about Firebase."
        )
    }

    /// Whether the app has settled on a signed-out welcome or a restored
    /// signed-in screen. Either is a valid resting state for this simulator;
    /// what must never happen is the launch screen hanging.
    private func settledScreen(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        app.buttons["Verification"].waitForExistence(timeout: timeout)
            || app.textFields["First name"].waitForExistence(timeout: 2)
            || app.staticTexts["When's your birthday?"].waitForExistence(timeout: 2)
            || app.staticTexts["Hey there 👋"].waitForExistence(timeout: 2)
    }

    /// Welcome, on real Firebase, offers exactly one way in: the phone OTP
    /// flow. No OAuth rows, no guest entry.
    func testWelcomeOffersOnlyThePhoneFlow() {
        let app = launchLive(reset: true)

        // A restored session from a previous run may skip welcome entirely;
        // that is a pass for restoration, not a failure of this test.
        guard app.buttons["Verification"].waitForExistence(timeout: 30) else {
            XCTAssertTrue(
                settledScreen(app, timeout: 5),
                "The app must settle on a real screen, not hang on launch"
            )
            return
        }

        assertOnRealFirebase(app, "At Welcome")
        XCTAssertTrue(app.textFields["phone.number"].exists, "The phone input must be present")
        XCTAssertFalse(app.buttons["Continue with Google"].exists, "No Google sign-in may exist")
        XCTAssertFalse(app.buttons["Continue with Apple"].exists, "No Apple sign-in may exist")
        XCTAssertFalse(
            app.buttons["Continue as Guest"].exists,
            "Anonymous auth is removed; no guest entry may exist"
        )
    }

    /// A cold launch must settle into a real screen. This is the regression
    /// the deny-all ruleset produced (the app hung restoring a session), so it
    /// stays explicit rather than implied.
    func testColdLaunchDoesNotHangOrStrand() {
        let app = launchLive(reset: false)
        assertOnRealFirebase(app, "On cold launch")

        XCTAssertTrue(
            settledScreen(app, timeout: 30),
            "The app must settle into a real screen, not hang on launch"
        )
    }
}

extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
