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
final class ScreenshotCaptureUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
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

        visit(app, tab: "Calls", name: "03-calls", settle: 4)
        visit(app, tab: "Matches", name: "04-matches", settle: 4)
        visit(app, tab: "Chat", name: "05-chat", settle: 4)
        visit(app, tab: "Profile", name: "06-profile", settle: 4)
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
        phoneField.typeText("6505551234")

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
        codeField.typeText("123456") // verifies automatically at the sixth digit
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
