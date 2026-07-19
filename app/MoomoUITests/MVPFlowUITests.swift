import XCTest

/// The MVP journeys end to end: Discover → call → decision → match → chat,
/// and the four tabs that used to say "Not built yet."
///
/// All on the mock backend (`-use-mock-backend`) — these assert UI behaviour,
/// not backend behaviour. The featured person (Kenji) "wants to talk", and
/// the simulated peer always likes those back, so the match path is
/// deterministic.
final class MVPFlowUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing-reset", "-use-mock-backend"]
        app.launch()
        return app
    }

    /// The chat composer. A multi-line SwiftUI `TextField` can surface to
    /// XCUITest as either a text field or a text view depending on OS
    /// version, so match whichever exists.
    private func chatInput(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textFields["chat.input"]
        if field.waitForExistence(timeout: 6) { return field }
        return app.textViews["chat.input"]
    }

    /// Signs in with the mock phone flow, completes the full onboarding
    /// (anonymous auth — and the guest short flow with it — is gone), and
    /// lands on Discover. Needs a seeded simulator photo library for the
    /// photos step.
    private func launchToDiscover() -> XCUIApplication {
        let app = launch()

        // Welcome: consent, phone number, SMS code (the mock accepts 123456).
        let checkbox = app.buttons["I have read and agree to the Privacy Policy and Terms of Service"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        checkbox.tap()

        let phoneField = app.textFields["phone.number"]
        XCTAssertTrue(phoneField.waitForExistence(timeout: 5))
        phoneField.tap()
        phoneField.typeText("5550100200")
        app.buttons["Verification"].firstMatch.tap()

        let codeField = app.textFields["otp.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 8), "The OTP screen must appear")
        codeField.tap()
        codeField.typeText("123456")

        let nameField = app.textFields["First name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        nameField.tap()
        nameField.typeText("Sam")
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["When's your birthday?"].waitForExistence(timeout: 4))
        let wheels = app.datePickers.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 4))
        wheels.element(boundBy: wheels.count - 1).adjust(toPickerWheelValue: "2000")
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["How do you identify?"].waitForExistence(timeout: 4))
        app.buttons["Non-binary"].firstMatch.tap()
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Who would you like to meet?"].waitForExistence(timeout: 4))
        app.buttons["Everyone"].firstMatch.tap()
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Where are you?"].waitForExistence(timeout: 4))
        app.buttons["Chicago, United States"].firstMatch.tap()
        app.buttons["Continue"].firstMatch.tap()

        // Photos: one through the system picker, then wait for the upload.
        XCTAssertTrue(app.staticTexts["Add your photos"].waitForExistence(timeout: 5))
        app.buttons["photos.add"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["Photos"].waitForExistence(timeout: 10),
            "The native PhotosPicker must open"
        )
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
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Tell us about you"].waitForExistence(timeout: 4))
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["What are you into?"].waitForExistence(timeout: 4))
        app.buttons["Coffee"].firstMatch.tap()
        app.buttons["Hiking"].firstMatch.tap()
        app.buttons["Travel"].firstMatch.tap()
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Camera & microphone"].waitForExistence(timeout: 4))
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Stay in the loop"].waitForExistence(timeout: 4))
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Be real, be kind"].waitForExistence(timeout: 4))
        app.switches.firstMatch.tap()
        app.buttons["Continue"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Looking good"].waitForExistence(timeout: 4))
        app.buttons["Start meeting people"].firstMatch.tap()

        XCTAssertTrue(
            app.staticTexts["Hey there 👋"].waitForExistence(timeout: 10),
            "Onboarding must finish into Discover"
        )
        return app
    }

    /// Runs one video call with the featured person through to the decision
    /// screen: Talk to Him → searching → live call → End Call.
    private func runCallToDecision(_ app: XCUIApplication) {
        let talk = app.buttons["Talk to Him"]
        XCTAssertTrue(talk.waitForExistence(timeout: 8), "The hero card must load")
        talk.tap()

        // Searching (~1.4s) then connecting (~0.9s) then the live call.
        let endCall = app.buttons["call.end"]
        XCTAssertTrue(endCall.waitForExistence(timeout: 12), "Matchmaking must reach a live call")
        XCTAssertTrue(app.staticTexts["3-Minute Speed Call"].exists)
        XCTAssertTrue(app.staticTexts["call.timer"].exists, "The countdown must be visible")

        endCall.tap()

        XCTAssertTrue(
            app.staticTexts["Call ended!"].waitForExistence(timeout: 4),
            "Ending the call must reach the decision screen"
        )
    }

    // MARK: - The core loop

    func testDiscoverCallLikeMatchAndChatJourney() {
        let app = launchToDiscover()

        runCallToDecision(app)

        // Like → mutual (Kenji wants to talk) → It's a Match.
        app.buttons["call.decision.like"].tap()
        XCTAssertTrue(
            app.staticTexts["It's a Match!"].waitForExistence(timeout: 6),
            "A mutual like must celebrate"
        )

        // Straight into the conversation.
        app.buttons["call.match.sendMessage"].tap()
        let input = chatInput(app)
        XCTAssertTrue(input.waitForExistence(timeout: 6), "The match's chat must open")
        input.tap()
        input.typeText("Hey! Great call")
        app.buttons["chat.send"].tap()

        XCTAssertTrue(
            app.staticTexts["Hey! Great call"].waitForExistence(timeout: 4),
            "The sent message must appear in the thread"
        )

        // The tab bar is hidden inside a thread (it would sit on the
        // composer) — back out to the list to get it back.
        app.navigationBars.buttons.firstMatch.tap()

        // The match shows on the Matches tab…
        XCTAssertTrue(app.buttons["Matches"].waitForExistence(timeout: 4))
        app.buttons["Matches"].tap()
        XCTAssertTrue(
            app.buttons["matches.card.Kenji"].waitForExistence(timeout: 4),
            "The new match must be listed"
        )

        // …and the call shows in history with its outcome.
        app.buttons["Calls"].tap()
        XCTAssertTrue(
            app.otherElements["calls.row.Kenji"].firstMatch.waitForExistence(timeout: 4)
            || app.staticTexts["Kenji"].waitForExistence(timeout: 2),
            "The finished call must be in history"
        )
        XCTAssertTrue(app.staticTexts["Matched"].exists, "History must show the outcome")
    }

    func testPassAfterCallCreatesNoMatch() {
        let app = launchToDiscover()

        runCallToDecision(app)

        app.buttons["call.decision.pass"].tap()

        // Passing returns to Discover with no celebration.
        XCTAssertTrue(app.staticTexts["Hey there 👋"].waitForExistence(timeout: 6))

        app.buttons["Matches"].tap()
        XCTAssertTrue(
            app.otherElements["matches.emptyState"].waitForExistence(timeout: 4)
            || app.staticTexts["No matches yet"].waitForExistence(timeout: 2),
            "A pass must never create a match"
        )
    }

    // MARK: - Matches → chat

    func testMatchCardOpensChatAndMessageSends() {
        let app = launchToDiscover()
        runCallToDecision(app)
        app.buttons["call.decision.like"].tap()
        XCTAssertTrue(app.staticTexts["It's a Match!"].waitForExistence(timeout: 6))
        app.buttons["call.match.keepBrowsing"].tap()

        app.buttons["Matches"].tap()
        let card = app.buttons["matches.card.Kenji"]
        XCTAssertTrue(card.waitForExistence(timeout: 4))
        card.tap()

        let input = chatInput(app)
        XCTAssertTrue(input.waitForExistence(timeout: 6), "Tapping a match must open its chat")
        input.tap()
        input.typeText("Hi from Matches")
        app.buttons["chat.send"].tap()

        XCTAssertTrue(app.staticTexts["Hi from Matches"].waitForExistence(timeout: 4))
    }

    // MARK: - No placeholders anywhere

    func testCallsTabHasRealContentNotAPlaceholder() {
        let app = launchToDiscover()

        app.buttons["Calls"].tap()

        XCTAssertFalse(app.staticTexts["Not built yet."].exists)
        XCTAssertTrue(
            app.staticTexts["No calls yet"].waitForExistence(timeout: 4),
            "Calls must show a real empty state"
        )
        XCTAssertTrue(app.buttons["calls.startMatching"].exists, "…with a working CTA")

        // The CTA really navigates.
        app.buttons["calls.startMatching"].tap()
        XCTAssertTrue(app.staticTexts["Hey there 👋"].waitForExistence(timeout: 4))
    }

    func testChatTabHasRealContentNotAPlaceholder() {
        let app = launchToDiscover()

        app.buttons["Chat"].tap()

        XCTAssertFalse(app.staticTexts["Not built yet."].exists)
        XCTAssertTrue(
            app.staticTexts["No conversations yet"].waitForExistence(timeout: 4),
            "Chat must show a real empty state"
        )
    }

    // MARK: - Discover header actions

    func testBellOpensNotificationsAndBoostOpensBoost() {
        let app = launchToDiscover()

        app.buttons["discover.bell"].tap()
        XCTAssertTrue(
            app.navigationBars["Notifications"].waitForExistence(timeout: 4),
            "The bell must open Notifications"
        )
        app.buttons["Close"].tap()

        app.buttons["discover.boost"].tap()
        XCTAssertTrue(
            app.navigationBars["Boost"].waitForExistence(timeout: 4),
            "Boost must open the Boost screen"
        )
        let activate = app.buttons["boost.activate"]
        XCTAssertTrue(activate.waitForExistence(timeout: 2))
        activate.tap()
        XCTAssertTrue(
            app.staticTexts["You're boosted!"].waitForExistence(timeout: 4),
            "Activating a boost must flip real state"
        )
    }
}
