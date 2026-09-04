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

    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing-reset", "-use-mock-backend"] + extraArguments
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
    private func launchToDiscover(extraArguments: [String] = []) -> XCUIApplication {
        let app = launch(extraArguments: extraArguments)

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

        XCTAssertTrue(app.staticTexts["What are you looking for?"].waitForExistence(timeout: 4))
        app.buttons["intention.longTerm"].firstMatch.tap()
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
            app.staticTexts["CHAT MODES"].waitForExistence(timeout: 10),
            "Onboarding must finish into Discover"
        )
        return app
    }

    /// Runs one video call with the featured person through to the decision
    /// screen: Nearby → searching → live call → End Call.
    private func runCallToDecision(_ app: XCUIApplication) {
        let talk = app.buttons["discover.nearby"]
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
        XCTAssertTrue(app.staticTexts["CHAT MODES"].waitForExistence(timeout: 6))

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
        XCTAssertTrue(app.staticTexts["CHAT MODES"].waitForExistence(timeout: 4))
    }

    // MARK: - Chat row swipe actions

    /// Swiping a conversation row left must reveal Unmatch / Hide / We Met,
    /// Hide must move the row into the Hidden section, and the hidden row's
    /// swipe must offer Unhide and restore it. Regression: the drag was
    /// attached with `.gesture`, which never fires inside a `ScrollView`
    /// (the scroll pan claims the touches), so swiping did nothing.
    func testSwipeLeftOnChatRowRevealsActionsAndHideUnhideWork() {
        let app = launchToDiscover()
        runCallToDecision(app)

        app.buttons["call.decision.like"].tap()
        XCTAssertTrue(app.staticTexts["It's a Match!"].waitForExistence(timeout: 6))
        app.buttons["call.match.sendMessage"].tap()
        XCTAssertTrue(chatInput(app).waitForExistence(timeout: 6), "The match's chat must open")
        app.navigationBars.buttons.firstMatch.tap() // back to the chat list

        // The fresh conversation sits under "Your turn"; nothing is hidden.
        let row = app.buttons["chat.row.Kenji"]
        XCTAssertTrue(row.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["chat.section.yourTurn"].exists)
        XCTAssertFalse(app.buttons["chat.section.hidden"].exists)

        swipeRowLeft(row, in: app)
        let hide = app.buttons["Hide"].firstMatch
        XCTAssertTrue(
            waitUntilHittable(hide),
            "Swiping a row left must reveal its actions"
        )
        // Regression: the swipe's touch-up used to ALSO fire the row's tap
        // (Button fires on touch-up-inside even after a drag) and push the
        // thread over the revealed actions.
        XCTAssertTrue(
            app.buttons["chat.section.yourTurn"].exists,
            "A swipe must reveal actions without opening the thread"
        )
        XCTAssertTrue(app.buttons["Unmatch"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["We Met"].firstMatch.isHittable)
        hide.tap()

        // Hide moves the row into the Hidden section…
        XCTAssertTrue(
            app.buttons["chat.section.hidden"].waitForExistence(timeout: 4),
            "Hiding the only conversation must create the Hidden section"
        )

        // …where its swipe offers Unhide, which restores it.
        swipeRowLeft(row, in: app)
        let unhide = app.buttons["Unhide"].firstMatch
        XCTAssertTrue(waitUntilHittable(unhide), "A hidden row must offer Unhide")
        unhide.tap()

        XCTAssertTrue(app.buttons["chat.section.yourTurn"].waitForExistence(timeout: 4))
        let hiddenGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["chat.section.hidden"]
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [hiddenGone], timeout: 4), .completed,
            "Unhiding the only hidden conversation must remove the section"
        )

        // A plain tap — no drag — still opens the thread.
        row.tap()
        XCTAssertTrue(
            chatInput(app).waitForExistence(timeout: 6),
            "Tapping a row must still open its conversation"
        )
    }

    /// A controlled horizontal drag across the row, like a finger swipe.
    private func swipeRowLeft(_ row: XCUIElement, in app: XCUIApplication) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// The action buttons exist in the hierarchy even while covered by the
    /// row content, so `exists` cannot prove the swipe worked — only
    /// hittability can.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
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

    // MARK: - Video Match

    /// Video Match through a live call: the plain video call and nothing
    /// else. The tile is on Discover, it starts an ordinary call, and the
    /// two things that belong to Go Play — the Games button and the prompt
    /// cards — stay out of it. Every control is where a call needs it.
    ///
    /// `-ui-testing-fast-icebreakers` is passed on purpose: it compresses the
    /// prompt schedule, so if anything still scheduled a run from the top of
    /// the call the card would be on screen well inside this test's window.
    /// Nothing does, and this is what proves it.
    func testVideoMatchIsAnOrdinaryVideoCall() {
        let app = launchToDiscover(extraArguments: ["-ui-testing-fast-icebreakers"])

        let videoMatch = app.buttons["discover.videoMatch"]
        XCTAssertTrue(videoMatch.waitForExistence(timeout: 8), "Discover must offer Video Match")
        videoMatch.tap()

        let endCall = app.buttons["call.end"]
        XCTAssertTrue(endCall.waitForExistence(timeout: 25), "Video Match must reach a live call")
        XCTAssertTrue(app.staticTexts["3-Minute Speed Call"].exists)
        XCTAssertTrue(app.staticTexts["call.timer"].exists, "The countdown must be visible")

        // Every call control, exactly where a call needs it.
        XCTAssertTrue(app.buttons["call.mute"].exists, "Mute must stay reachable")
        XCTAssertTrue(app.buttons["call.flipCamera"].exists, "The flip-camera control must stay reachable")
        XCTAssertTrue(app.buttons["call.end"].exists, "End Call must stay reachable")
        XCTAssertTrue(app.buttons["call.more"].exists, "Report and block must stay reachable")
        XCTAssertTrue(app.buttons["call.minimise"].exists, "Minimise must stay reachable")

        // Neither half of Go Play may appear here.
        XCTAssertFalse(
            app.buttons["call.games"].exists,
            "The Games button belongs to Go Play and must not be on a Video Match call"
        )

        // Give the compressed schedule more than enough time to fire, then
        // assert that nothing did.
        XCTAssertFalse(
            app.otherElements["icebreaker.card"].waitForExistence(timeout: 20),
            "No prompt card may arrive on its own during a Video Match call"
        )

        // Still a plain call, still controllable.
        XCTAssertTrue(app.staticTexts["3-Minute Speed Call"].exists)
        XCTAssertTrue(endCall.exists)
        XCTAssertTrue(app.buttons["call.mute"].exists)
    }

    /// The prompts have one door, and it is Go Play's picker. Closing them
    /// hands the pair back the call they were already on.
    func testClosingTheIcebreakersLeavesTheCallRunning() {
        let app = launchToDiscover(extraArguments: ["-ui-testing-fast-icebreakers"])

        let goPlay = app.buttons["discover.goPlay"]
        XCTAssertTrue(goPlay.waitForExistence(timeout: 8))
        goPlay.tap()
        XCTAssertTrue(
            app.buttons["call.end"].waitForExistence(timeout: 25),
            "Go Play must reach a live call"
        )

        let games = app.buttons["call.games"]
        XCTAssertTrue(games.waitForExistence(timeout: 8))
        games.tap()

        let icebreakers = app.buttons["callgames.game.icebreakers"]
        XCTAssertTrue(icebreakers.waitForExistence(timeout: 5))
        icebreakers.tap()

        let close = app.buttons["icebreaker.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20), "The card must be closeable")
        close.tap()

        // The card leaves on a transition, so give it the beat it animates
        // for rather than reading the hierarchy mid-flight.
        XCTAssertTrue(
            app.otherElements["icebreaker.card"].waitForNonExistence(timeout: 4),
            "Closing must take the cards away"
        )
        XCTAssertTrue(app.staticTexts["3-Minute Speed Call"].exists, "The call is untouched")
        XCTAssertTrue(app.buttons["call.end"].exists)
    }

    // MARK: - Chat modes

    /// Both tiles are on Discover, and both start a video call — one pool,
    /// two experiences. Nothing here starts an audio-only call: `.voice` is
    /// decode-only and has no button on this screen or any other.
    func testChatModesOffersVideoMatchAndGoPlay() {
        let app = launchToDiscover()

        XCTAssertTrue(
            app.staticTexts["CHAT MODES"].waitForExistence(timeout: 8),
            "Discover must have a chat-modes row"
        )

        let videoMatch = app.buttons["discover.videoMatch"]
        XCTAssertTrue(videoMatch.waitForExistence(timeout: 8), "Video Match must be offered")
        XCTAssertTrue(videoMatch.isHittable, "Video Match must be tappable")

        let goPlay = app.buttons["discover.goPlay"]
        XCTAssertTrue(goPlay.waitForExistence(timeout: 8), "Go Play must be offered")
        XCTAssertTrue(goPlay.isHittable, "Go Play must be tappable")

        // The retired voice-only tile must never come back.
        XCTAssertFalse(app.staticTexts["Speed Talk"].exists, "Speed Talk is retired")
        XCTAssertFalse(app.staticTexts["Real Talk"].exists, "Real Talk is retired")

        // And the hero still offers the directed call alongside them.
        XCTAssertTrue(
            app.buttons["discover.nearby"].waitForExistence(timeout: 8),
            "Nearby must still start a video call"
        )
    }

    /// With nobody in the pool there is no hero, and the empty card carries
    /// Nearby so the screen still has a way into a call: it joins the queue
    /// and waits for whoever turns up next.
    func testNearbyIsStillOfferedWhenNobodyIsAround() {
        let app = launchToDiscover(extraArguments: ["-ui-testing-empty-discovery"])

        XCTAssertTrue(
            app.staticTexts["No one's around"].waitForExistence(timeout: 10),
            "An empty pool must reach the empty card"
        )

        let nearby = app.buttons["discover.nearby"]
        XCTAssertTrue(
            nearby.waitForExistence(timeout: 8),
            "Nearby must still be offered when there is nobody to feature"
        )
        XCTAssertTrue(nearby.isHittable, "Nearby must be tappable on the empty card")

        // And it really starts matchmaking rather than just sitting there.
        nearby.tap()
        XCTAssertTrue(
            app.buttons["call.end"].waitForExistence(timeout: 25),
            "Nearby on the empty card must reach a live call"
        )
    }

    // MARK: - Go Play

    /// Discover's Go Play tile through a live video call and into the game
    /// picker: the list is there, the games that are not built yet say so,
    /// and choosing one that is takes both people into it — with the call
    /// running underneath the whole time.
    func testGoPlayTileReachesTheGamePickerInsideTheCall() {
        let app = launchToDiscover(extraArguments: ["-ui-testing-fast-icebreakers"])

        // Go Play replaced Speed Talk, and it starts a video call.
        XCTAssertFalse(
            app.staticTexts["Speed Talk"].exists,
            "The voice-only tile must be gone from Discover"
        )
        let goPlay = app.buttons["discover.goPlay"]
        XCTAssertTrue(goPlay.waitForExistence(timeout: 8), "Discover must offer Go Play")
        goPlay.tap()

        // Matchmaking lands on the ordinary live call.
        let endCall = app.buttons["call.end"]
        XCTAssertTrue(endCall.waitForExistence(timeout: 25), "Go Play must reach a live call")
        XCTAssertTrue(app.staticTexts["3-Minute Speed Call"].exists)
        XCTAssertTrue(app.buttons["call.mute"].exists, "A video call must be mutable")
        XCTAssertTrue(app.buttons["call.flipCamera"].exists, "A video call must have a flip-camera control")

        // Go Play does not run the prompts by itself — these two came here to
        // choose something together.
        XCTAssertFalse(
            app.otherElements["icebreaker.card"].exists,
            "Go Play must not open a prompt over the picker"
        )

        // Games opens the list.
        let games = app.buttons["call.games"]
        XCTAssertTrue(games.waitForExistence(timeout: 8), "A Go Play call must offer the game list")
        games.tap()

        let picker = app.otherElements["callgames.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "The picker must open inside the call")

        // The roadmap is on the list, honestly marked, and unselectable.
        for game in ["snakeClash", "ludo", "chase", "cards"] {
            let row = app.buttons["callgames.game.\(game)"]
            XCTAssertTrue(row.exists, "\(game) must be listed")
            XCTAssertFalse(row.isEnabled, "\(game) is not built yet and must not be selectable")
        }

        // Opening the list touched nothing about the call.
        XCTAssertTrue(app.staticTexts["3-Minute Speed Call"].exists)
        XCTAssertTrue(endCall.exists)

        // Choosing the one that is built proposes it; the stand-in accepts.
        let icebreakers = app.buttons["callgames.game.icebreakers"]
        XCTAssertTrue(icebreakers.isEnabled, "Icebreakers is built and must be selectable")
        icebreakers.tap()

        XCTAssertTrue(
            app.otherElements["icebreaker.card"].waitForExistence(timeout: 20),
            "Accepting must put the chosen game on screen"
        )
        XCTAssertTrue(
            app.staticTexts["3-Minute Speed Call"].exists,
            "Starting a game must not end or restart the call"
        )
        XCTAssertTrue(app.buttons["call.end"].exists, "End Call must stay reachable inside a game")
        XCTAssertTrue(app.buttons["call.more"].exists, "Report and block must stay reachable")
    }

    /// Cancelling a proposal leaves the call exactly as it was.
    func testCancellingAGameProposalLeavesTheCallRunning() {
        let app = launchToDiscover()

        let goPlay = app.buttons["discover.goPlay"]
        XCTAssertTrue(goPlay.waitForExistence(timeout: 8), "Discover must offer Go Play")
        goPlay.tap()
        XCTAssertTrue(
            app.buttons["call.end"].waitForExistence(timeout: 25),
            "Go Play must reach a live call"
        )

        let games = app.buttons["call.games"]
        XCTAssertTrue(games.waitForExistence(timeout: 8))
        games.tap()

        let icebreakers = app.buttons["callgames.game.icebreakers"]
        XCTAssertTrue(icebreakers.waitForExistence(timeout: 5))
        icebreakers.tap()

        // Withdraw it before the stand-in answers, if we get there in time.
        let cancel = app.buttons["callgames.invite.cancel"]
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        }

        XCTAssertTrue(app.staticTexts["3-Minute Speed Call"].exists, "The call is untouched")
        XCTAssertTrue(app.buttons["call.end"].exists)
    }

    // MARK: - Discover location bar

    /// Both halves of the location bar reach the picker, and the picker
    /// commits a city back to the bar. The bell and Boost buttons this test
    /// used to cover are gone from Discover — the header went with them.
    func testLocationBarOpensThePickerAndSavesACity() {
        let app = launchToDiscover()

        let bar = app.buttons["discover.locationBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 6), "Discover must show the location bar")
        bar.tap()

        XCTAssertTrue(
            app.navigationBars["Your city"].waitForExistence(timeout: 4),
            "The location bar must open the picker"
        )

        // Search resolves against the bundled catalogue with no network, so
        // this half of the picker is deterministic on a simulator.
        let search = app.textFields["Search for a city"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.tap()
        search.typeText("Toronto")

        let result = app.buttons["Toronto, ON"]
        XCTAssertTrue(result.waitForExistence(timeout: 8), "Search must offer a matching city")
        result.tap()

        let save = app.buttons["location.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 4))
        save.tap()

        XCTAssertTrue(bar.waitForExistence(timeout: 6), "Saving must return to Discover")
        // The bar is one combined accessibility element, so the city shows up
        // in its label rather than as a static text of its own.
        let named = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'Toronto, ON'"),
            object: bar
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [named], timeout: 8), .completed,
            "The bar must show the city that was just picked"
        )
    }

    /// The bar's right half is the dating intention, not a second door to the
    /// city picker, and what it saves shows up on the bar.
    func testIntentionHalfOpensItsOwnPickerAndSaves() {
        let app = launchToDiscover()

        let intent = app.buttons["discover.intention"]
        XCTAssertTrue(intent.waitForExistence(timeout: 6))
        intent.tap()

        XCTAssertTrue(
            app.navigationBars["Looking for"].waitForExistence(timeout: 4),
            "The right half must open the intention picker, not the city picker"
        )
        XCTAssertFalse(
            app.navigationBars["Your city"].exists,
            "The two halves must not share a destination"
        )

        app.buttons["intention.longTerm"].tap()
        app.buttons["intention.save"].tap()

        XCTAssertTrue(intent.waitForExistence(timeout: 6), "Saving must return to Discover")
        let named = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'Long-term relationship'"),
            object: intent
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [named], timeout: 8), .completed,
            "The bar must show the intention that was just picked"
        )
    }

    // MARK: - Layout stability

    /// Discover must not change shape once it is on screen.
    ///
    /// The feed arrives a beat after the screen does, and the card that stands
    /// in for it while it loads used to be some fifty points shorter than the
    /// hero that replaced it — so the whole screen below the hero slot visibly
    /// jumped a moment after Discover opened. Both halves are asserted from
    /// one launch: the chat-mode tiles are in exactly the same place, and are
    /// the same size as each other, before and after the hero lands.
    ///
    /// `-ui-testing-slow-discovery` stretches the mock's answer so the
    /// skeleton is unambiguously still up for the first measurement rather
    /// than the test racing it.
    func testDiscoverDoesNotReflowWhenTheFeedArrives() {
        let app = launchToDiscover(extraArguments: ["-ui-testing-slow-discovery"])

        let videoMatch = app.buttons["discover.videoMatch"]
        let goPlay = app.buttons["discover.goPlay"]
        XCTAssertTrue(videoMatch.waitForExistence(timeout: 8), "Video Match must be offered")

        // Still loading: the hero's Nearby has not arrived yet, so what is on
        // screen is the skeleton.
        XCTAssertFalse(
            app.buttons["discover.nearby"].exists,
            "The feed must still be loading — raise -ui-testing-slow-discovery if this trips"
        )
        let loadingVideoMatch = videoMatch.frame
        let loadingGoPlay = goPlay.frame
        attach(app.screenshot(), named: "discover-loading")

        // The hero lands.
        XCTAssertTrue(
            app.buttons["discover.nearby"].waitForExistence(timeout: 20),
            "The feed must arrive"
        )
        attach(app.screenshot(), named: "discover-loaded")

        assertUnmoved(
            videoMatch.frame, loadingVideoMatch,
            "The Video Match tile must not move when the feed arrives"
        )
        assertUnmoved(
            goPlay.frame, loadingGoPlay,
            "The Go Play tile must not move when the feed arrives"
        )
        XCTAssertEqual(
            loadingVideoMatch.size, loadingGoPlay.size,
            "The two chat-mode tiles must be identically sized"
        )
    }

    /// A Video Match call screen must be the size it was at first paint.
    ///
    /// Video Match is the plain call, so nothing may arrive over it and
    /// nothing may shrink its controls: mute, camera, and End Call have to be
    /// under the same thumb for the whole three minutes. The wait below is the
    /// compressed prompt schedule's whole window, so anything that was going
    /// to open by itself has had its chance by the time the frames are
    /// compared.
    func testVideoMatchCallScreenDoesNotResizeAfterItOpens() {
        let app = launchToDiscover(extraArguments: ["-ui-testing-fast-icebreakers"])

        let videoMatch = app.buttons["discover.videoMatch"]
        XCTAssertTrue(videoMatch.waitForExistence(timeout: 8))
        videoMatch.tap()

        let endCall = app.buttons["call.end"]
        let mute = app.buttons["call.mute"]
        let flipCamera = app.buttons["call.flipCamera"]
        XCTAssertTrue(endCall.waitForExistence(timeout: 25), "Video Match must reach a live call")

        let firstEnd = endCall.frame
        let firstMute = mute.frame
        let firstFlipCamera = flipCamera.frame
        attach(app.screenshot(), named: "call-opened")

        XCTAssertFalse(
            app.otherElements["icebreaker.card"].waitForExistence(timeout: 12),
            "No card may arrive on its own during a Video Match call"
        )
        attach(app.screenshot(), named: "call-settled")

        assertUnmoved(endCall.frame, firstEnd, "End Call must not move or resize mid-call")
        assertUnmoved(mute.frame, firstMute, "Mute must not move or resize mid-call")
        assertUnmoved(flipCamera.frame, firstFlipCamera, "The flip-camera control must not move or resize")
    }

    /// Frames are compared to within half a point: the assertion is about a
    /// visible jump, not about floating-point identity.
    private func assertUnmoved(
        _ actual: CGRect,
        _ expected: CGRect,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, message, file: file, line: line)
    }

    /// Kept only when the test fails, which is the run where the before and
    /// after pictures are worth having.
    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
