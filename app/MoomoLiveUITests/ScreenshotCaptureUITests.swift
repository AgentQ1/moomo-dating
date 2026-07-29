import XCTest

/// Drives the real app against live Firebase and captures App Store
/// screenshots. Not a regression test — a capture harness. It signs in with a
/// Firebase console *test phone number* (no real SMS is sent), walks the main
/// tabs, and writes a PNG per screen.
///
/// Screenshots land in the directory named by the `SCREENSHOT_DIR` runner
/// environment variable (pass via `TEST_RUNNER_SCREENSHOT_DIR`), and are also
/// attached to the result bundle as a fallback.
///
///     xcodebuild test-without-building -project Moomo.xcodeproj \
///       -scheme MoomoLiveUI \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///       -only-testing:MoomoLiveUITests/ScreenshotCaptureUITests
///
/// A speed call and a conversation both need a second person, so the account is
/// selectable (`SCREENSHOT_PHONE` / `SCREENSHOT_CODE`) and two of the tests are
/// there to be run on a *second* simulator as that person: `testActAsCallPeer`
/// waits in the matchmaking queue, `testSendMessagesAsPeer` sends chat lines
/// named by `SCREENSHOT_MESSAGES`.
final class ScreenshotCaptureUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

    /// The Firebase console test number to sign in with — Solan by default,
    /// overridden on the peer simulator.
    private var phoneNumber: String {
        env("SCREENSHOT_PHONE") ?? "6505551234"
    }

    private var verificationCode: String {
        env("SCREENSHOT_CODE") ?? "123456"
    }

    private func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    func testCaptureAppStoreScreenshots() {
        let app = XCUIApplication()
        app.launch()

        signInIfNeeded(app)

        // Land on the tab bar; Discover is the default tab.
        XCTAssertTrue(
            app.buttons["Profile"].waitForExistence(timeout: 60),
            "Main tab bar never appeared — sign-in failed or the account has no profile"
        )
        // Let the Discover feed load before the first shot.
        sleep(6)
        snap(app, "02-discover")

        captureBoost(app)
        captureSearch(app)

        visit(app, tab: "Calls", name: "05-calls", settle: 4)
        visit(app, tab: "Matches", name: "06-matches", settle: 4)
        visit(app, tab: "Chat", name: "07-chat", settle: 4)
        captureConversation(app)
        visit(app, tab: "Profile", name: "09-profile", settle: 4)
        captureSafety(app)
    }

    /// The free daily boost, opened from the Discover header.
    private func captureBoost(_ app: XCUIApplication) {
        let boost = app.buttons["discover.boost"]
        guard boost.waitForExistence(timeout: 10) else {
            XCTFail("Boost button not found on Discover")
            return
        }
        boost.tap()
        XCTAssertTrue(app.buttons["boost.activate"].waitForExistence(timeout: 15)
                      || app.staticTexts["boost.activeUntil"].waitForExistence(timeout: 1),
                      "Boost sheet never presented")
        sleep(2)
        snap(app, "03-boost")
        dismissSheet(app)
    }

    /// Matchmaking in progress. This really does join the production queue, so
    /// the search is cancelled again as soon as the shot is taken.
    private func captureSearch(_ app: XCUIApplication) {
        // The hero CTA is titled "Talk to Her"/"Talk to Him" after the pronoun
        // of whoever is featured, so match on the stable prefix instead.
        let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Talk to'")).firstMatch
        guard cta.waitForExistence(timeout: 15) else {
            XCTFail("Discover hero CTA not found — no one is waiting")
            return
        }
        cta.tap()

        let cancel = app.buttons["call.cancelSearch"]
        guard cancel.waitForExistence(timeout: 20) else {
            XCTFail("Search screen never appeared")
            return
        }
        sleep(2)
        snap(app, "04-searching")
        if cancel.exists { cancel.tap() }
        sleep(4)
    }

    /// A real conversation, opened from the Chat tab.
    private func captureConversation(_ app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.row.'")).firstMatch
        guard row.waitForExistence(timeout: 15) else {
            XCTFail("No conversations to open — the account has no matches")
            return
        }
        row.tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 15)
                      || app.textViews["chat.input"].waitForExistence(timeout: 1),
                      "Chat detail never opened")
        sleep(3)
        snap(app, "08-conversation")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(2)
    }

    /// Safety & Privacy, reached from the Profile tab.
    private func captureSafety(_ app: XCUIApplication) {
        let row = app.buttons["profile.row.Safety & Privacy"]
        guard row.waitForExistence(timeout: 10) else {
            XCTFail("Safety & Privacy row not found on Profile")
            return
        }
        row.tap()
        sleep(3)
        snap(app, "10-safety")
        app.navigationBars.buttons.firstMatch.tap()
        sleep(2)
    }

    private func dismissSheet(_ app: XCUIApplication) {
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 5) {
            close.tap()
        } else {
            app.swipeDown(velocity: .fast)
        }
        sleep(2)
    }

    /// Completes the phone-OTP flow with the Firebase test number when the
    /// app launches signed out; a restored session skips this entirely.
    private func signInIfNeeded(_ app: XCUIApplication) {
        let phoneField = app.textFields["phone.number"]
        guard phoneField.waitForExistence(timeout: 30) else { return }

        // The signed-out welcome is itself the first screenshot.
        sleep(2)
        snap(app, "01-welcome")

        phoneField.tap()
        phoneField.typeText(phoneNumber)

        // The consent checkbox gates the CTA; agree before requesting a code.
        let consent = app.buttons["I have read and agree to the Privacy Policy and Terms of Service"]
        if consent.exists { consent.tap() }
        app.buttons["Verification"].tap()

        // Simulators may bounce through the invisible-reCAPTCHA web round trip
        // before the code screen appears, so wait generously.
        let codeField = app.textFields["otp.code"]
        XCTAssertTrue(
            codeField.waitForExistence(timeout: 90),
            "OTP screen never appeared after requesting the code"
        )
        codeField.tap()
        codeField.typeText(verificationCode) // verifies automatically at the sixth digit
    }

    // MARK: - The other end of the call

    /// Captures a real speed call. Run this while `testActAsCallPeer` is
    /// searching on a second simulator: both accounts land in the same
    /// matchmaking queue and the backend pairs them.
    func testCaptureLiveCall() {
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app)

        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 60), "Never reached the tab bar")
        sleep(4)

        XCTAssertTrue(searchUntilPaired(app), "Never got into a call — was the peer searching?")

        sleep(5) // let the countdown tick away from 3:00 and video settle
        snap(app, "11-call")

        // The after-call decision is the other half of the story.
        app.buttons["call.end"].tap()
        sleep(4)
        snap(app, "12-decision")
    }

    /// The peer side of `testCaptureLiveCall`: sign in and keep searching so
    /// there is someone in the queue to be paired with. Each search lasts
    /// ~30s before the client gives up, so it is restarted a few times.
    func testActAsCallPeer() {
        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app)

        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 60), "Never reached the tab bar")
        sleep(4)

        XCTAssertTrue(searchUntilPaired(app), "Never paired with anyone")

        // Stay on the call long enough for the other side to take its
        // screenshots, then hang up.
        sleep(40)
        if app.buttons["call.end"].exists { app.buttons["call.end"].tap() }
    }

    /// Joins the matchmaking queue, and rejoins each time the search gives up,
    /// until a call connects. The mute control only exists in the live call,
    /// so it is the signal that the call actually connected.
    private func searchUntilPaired(_ app: XCUIApplication, attempts: Int = 6) -> Bool {
        for _ in 1...attempts {
            let cta = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Talk to'")).firstMatch
            guard waitUntilHittable(cta, timeout: 30) else { return false }
            cta.tap()

            if app.buttons["call.mute"].waitForExistence(timeout: 60) { return true }

            // The search gave up ("No luck this time") or is still spinning —
            // either way, get back to Discover and rejoin the queue.
            for label in ["Back to Discover", "Cancel"] where app.buttons[label].exists {
                app.buttons[label].tap()
                break
            }
            sleep(4)
        }
        return false
    }

    /// Sends `SCREENSHOT_MESSAGES` (a `|`-separated list) to the conversation
    /// named by `SCREENSHOT_PEER`, so the chat screenshots show a real
    /// exchange rather than an empty thread.
    func testSendMessagesAsPeer() {
        let messages = (env("SCREENSHOT_MESSAGES") ?? "").split(separator: "|").map(String.init)
        try? XCTSkipIf(messages.isEmpty, "No SCREENSHOT_MESSAGES given")
        guard !messages.isEmpty else { return }

        let app = XCUIApplication()
        app.launch()
        signInIfNeeded(app)

        XCTAssertTrue(app.buttons["Chat"].waitForExistence(timeout: 60), "Never reached the tab bar")
        app.buttons["Chat"].tap()
        sleep(4)

        let peer = env("SCREENSHOT_PEER")
        let row = peer.map { app.buttons["chat.row.\($0)"] }
            ?? app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Conversation not found")
        row.tap()

        // The composer is a vertically-growing TextField, which surfaces as
        // either a text field or a text view depending on iOS build.
        var input = app.textFields["chat.input"]
        if !input.waitForExistence(timeout: 20) {
            input = app.textViews["chat.input"]
        }
        XCTAssertTrue(input.waitForExistence(timeout: 10), "Chat detail never opened")

        for message in messages {
            input.tap()
            input.typeText(message)
            app.buttons["chat.send"].tap()
            sleep(3)
        }
        sleep(3)
    }

    /// Existing is not enough for the hero CTA: coming back from a cancelled
    /// search it is on screen but still behind the dismissing cover, so a tap
    /// lands nowhere.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            usleep(500_000)
        }
        return false
    }

    private func visit(_ app: XCUIApplication, tab: String, name: String, settle: UInt32) {
        let button = app.buttons[tab]
        guard button.waitForExistence(timeout: 10) else {
            XCTFail("Tab \(tab) not found")
            return
        }
        button.tap()
        sleep(settle)
        snap(app, name)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCUIScreen.main.screenshot()
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            do {
                try shot.pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
            } catch {
                // Host path not writable from the runner — the attachment below
                // still preserves the image inside the result bundle.
            }
        }
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
