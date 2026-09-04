import XCTest
@testable import Moomo

/// Go Play's lobby, and the line between Discover's two experiences.
///
/// Both sides are real `GoPlaySessionModel`s wired to a
/// `LoopbackDataTransport` pair, so the invite/accept/decline handshake is
/// exercised as a genuine two-device conversation with no room and no
/// network.
@MainActor
final class CallGameLobbyTests: XCTestCase {

    private let aliceID = "a-alice"
    private let bobID = "z-bob"

    private func makePair() -> (
        alice: GoPlaySessionModel,
        bob: GoPlaySessionModel,
        aliceTransport: LoopbackDataTransport,
        bobTransport: LoopbackDataTransport
    ) {
        let (first, second) = LoopbackDataTransport.pair(aliceID, bobID)
        let alice = GoPlaySessionModel(
            transport: first,
            localSeat: CallGameSeat(id: aliceID, displayName: "Alice"),
            peerSeat: CallGameSeat(id: bobID, displayName: "Bob"),
            feedback: SilentIcebreakerFeedback()
        )
        let bob = GoPlaySessionModel(
            transport: second,
            localSeat: CallGameSeat(id: bobID, displayName: "Bob"),
            peerSeat: CallGameSeat(id: aliceID, displayName: "Alice"),
            feedback: SilentIcebreakerFeedback()
        )
        alice.begin()
        bob.begin()
        return (alice, bob, first, second)
    }

    private func settle(_ ms: UInt64 = 30) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    private func exchange(_ first: GoPlaySessionModel, _ second: GoPlaySessionModel) async {
        for _ in 0..<4 {
            await first.drainPendingSends()
            await second.drainPendingSends()
            await settle(15)
        }
    }

    // MARK: - Two experiences, not one

    /// Discover offers two modes and they must stay two. A call knows which
    /// one it is, and the live screen reads that rather than guessing.
    func testVideoMatchAndGoPlayAreSeparateExperiences() {
        XCTAssertEqual(
            Set(CallExperience.allCases), [.videoMatch, .goPlay],
            "Neither experience may be collapsed into the other"
        )
        XCTAssertNotEqual(CallExperience.videoMatch, CallExperience.goPlay)
    }

    func testACallDefaultsToVideoMatchAndCarriesTheExperienceItWasStartedWith() {
        let videoMatch = makeFlow(experience: .videoMatch)
        let goPlay = makeFlow(experience: .goPlay)
        let unspecified = makeFlow(experience: nil)

        XCTAssertEqual(videoMatch.experience, .videoMatch)
        XCTAssertEqual(goPlay.experience, .goPlay)
        XCTAssertEqual(
            unspecified.experience, .videoMatch,
            "An ordinary call — an answered ring included — is a Video Match"
        )
    }

    /// The shared-queue fallback, asserted rather than assumed.
    ///
    /// `CallExperience` is a client-side distinction: matchmaking pairs on
    /// `mode` alone, so BOTH experiences must join as `.video` and both must
    /// reach a live call from the one queue. If either ever sent a different
    /// mode, the two would silently stop being able to pair with each other —
    /// which is exactly the split this fallback is documented as not making.
    func testBothExperiencesJoinAsVideoAndReachACall() async {
        for experience in CallExperience.allCases {
            let flow = makeFlow(experience: experience)
            flow.start()
            try? await Task.sleep(for: .milliseconds(150))

            XCTAssertEqual(
                flow.mode, .video,
                "\(experience) must join the one shared queue as a video call"
            )
            guard case .active(let session) = flow.stage else {
                return XCTFail("\(experience) must reach a live call, got \(flow.stage)")
            }
            XCTAssertEqual(session.mode, .video)
            XCTAssertEqual(
                flow.experience, experience,
                "…while still knowing which experience it is"
            )
        }
    }

    // MARK: - The catalogue

    func testOnlyTheFinishedGameIsSelectable() {
        XCTAssertTrue(CallGame.icebreakers.isPlayable)
        for game in [CallGame.snakeClash, .ludo, .chase, .cards] {
            XCTAssertFalse(game.isPlayable, "\(game.title) is not built yet and must say so")
        }
    }

    func testEveryGameOnTheListIsNamedAndDescribed() {
        for game in CallGame.allCases {
            XCTAssertFalse(game.title.isEmpty)
            XCTAssertFalse(game.tagline.isEmpty)
            XCTAssertFalse(game.symbol.isEmpty)
        }
        XCTAssertEqual(
            CallGame.pickerOrder.first, .icebreakers,
            "What can be played now goes at the top of the list"
        )
        XCTAssertEqual(Set(CallGame.pickerOrder), Set(CallGame.allCases))
    }

    /// Cards is a conversation piece, not a casino. Nothing in its copy may
    /// suggest stakes, and nothing in the app may offer any.
    func testCardsMakesNoGamblingClaim() {
        let copy = (CallGame.cards.title + " " + CallGame.cards.tagline).lowercased()
        for word in ["bet", "wager", "stake", "chips", "buy-in", "cash", "win money", "jackpot"] {
            XCTAssertFalse(copy.contains(word), "Cards must not read as gambling: '\(word)'")
        }
    }

    // MARK: - The picker

    func testOpeningTheListTellsTheOtherPersonNothing() async {
        let (alice, _, aliceTransport, _) = makePair()

        alice.openPicker()
        await alice.drainPendingSends()

        XCTAssertEqual(alice.stage, .picking)
        XCTAssertTrue(aliceTransport.sent.isEmpty, "Browsing a list is not an offer")
    }

    func testClosingTheListLeavesTheCallAlone() async {
        let (alice, _, aliceTransport, _) = makePair()
        alice.openPicker()

        alice.closePicker()
        await alice.drainPendingSends()

        XCTAssertEqual(alice.stage, .idle)
        XCTAssertTrue(aliceTransport.sent.isEmpty)
    }

    func testUnbuiltGamesCannotBeProposed() async {
        let (alice, _, aliceTransport, _) = makePair()
        alice.openPicker()

        alice.propose(.ludo)
        await alice.drainPendingSends()

        XCTAssertEqual(alice.stage, .picking, "A coming-soon game must not start a handshake")
        XCTAssertTrue(aliceTransport.sent.isEmpty)
    }

    /// The picker is not the only thing that can reach the session, so
    /// "coming soon" has to be refused on the way in as well as on the way
    /// out — a peer on a newer build must not be able to open an empty screen
    /// here.
    func testAnInviteForAGameThisBuildCannotPlayIsIgnored() async throws {
        let (alice, _, _, bobTransport) = makePair()

        bobTransport.deliverToPeerForTesting(try CallGameCodec.encode(.init(
            sessionID: "g1", sequence: 1, senderID: bobID, kind: .invite, game: .ludo
        )))
        await settle()

        XCTAssertEqual(alice.stage, .idle, "An unplayable proposal is refused, not displayed")
    }

    // MARK: - The handshake

    func testProposingAndAcceptingPutsBothSidesInTheSameGame() async {
        let (alice, bob, _, _) = makePair()
        alice.openPicker()

        alice.propose(.icebreakers)
        await exchange(alice, bob)

        XCTAssertEqual(bob.stage, .inviteReceived(.icebreakers))
        bob.acceptInvite()
        await exchange(alice, bob)

        XCTAssertEqual(alice.stage, .playing(.icebreakers))
        XCTAssertEqual(bob.stage, .playing(.icebreakers))
        XCTAssertEqual(alice.activeGame, .icebreakers)
        XCTAssertEqual(bob.activeGame, .icebreakers)
    }

    func testDecliningPutsTheProposerBackOnTheList() async {
        let (alice, bob, _, _) = makePair()
        alice.propose(.icebreakers)
        await exchange(alice, bob)

        bob.declineInvite()
        await exchange(alice, bob)

        XCTAssertEqual(
            alice.stage, .picking,
            "They said no to that game, not to playing — the list stays open"
        )
        XCTAssertNotNil(alice.notice)
        XCTAssertEqual(bob.stage, .idle)
    }

    /// Both tapping at once must produce one game, not two — and both
    /// devices must reach the same answer without another round trip.
    func testSimultaneousProposalsResolveToOneGame() async {
        let (alice, bob, _, _) = makePair()

        alice.propose(.icebreakers)
        bob.propose(.icebreakers)
        await exchange(alice, bob)

        // The lower participant identity's proposal is the one that stands.
        XCTAssertEqual(alice.stage, .invitePending(.icebreakers))
        XCTAssertEqual(bob.stage, .inviteReceived(.icebreakers))
    }

    func testADuplicatedAcceptDoesNotStartTwoGames() async throws {
        let (alice, bob, _, bobTransport) = makePair()
        alice.propose(.icebreakers)
        await exchange(alice, bob)
        bob.acceptInvite()
        await exchange(alice, bob)
        let accept = try XCTUnwrap(
            bobTransport.sent.compactMap { CallGameCodec.decode($0.payload) }
                .first { $0.kind == .accept }
        )

        bobTransport.deliverToPeerForTesting(try CallGameCodec.encode(accept))
        await settle()

        XCTAssertEqual(alice.stage, .playing(.icebreakers), "Reliable is not exactly-once")
    }

    func testAnUnansweredProposalIsGivenUpOnRatherThanSpinningForever() async {
        let (alice, bob, _, _) = makePair()
        alice.propose(.icebreakers)
        await exchange(alice, bob)

        alice.invitationTimedOut()
        await exchange(alice, bob)

        XCTAssertEqual(alice.stage, .idle)
        XCTAssertNotNil(alice.notice, "A spinner with no end is worse than an honest 'no answer'")
        XCTAssertEqual(bob.stage, .idle, "…and the offer is withdrawn on their side too")
    }

    func testLeavingAGameTellsTheOtherPersonAndReturnsBothToTheCall() async {
        let (alice, bob, _, _) = makePair()
        alice.propose(.icebreakers)
        await exchange(alice, bob)
        bob.acceptInvite()
        await exchange(alice, bob)

        alice.leaveGame()
        await exchange(alice, bob)

        XCTAssertEqual(alice.stage, .idle)
        XCTAssertEqual(bob.stage, .idle)
        XCTAssertNil(bob.activeGame)
        XCTAssertNotNil(bob.notice)
    }

    func testThePeerLeavingTheRoomEndsTheGame() async {
        let (alice, bob, aliceTransport, _) = makePair()
        alice.propose(.icebreakers)
        await exchange(alice, bob)
        bob.acceptInvite()
        await exchange(alice, bob)

        // The room Alice is in loses its other participant.
        aliceTransport.simulatePeerLeft()
        await settle()

        XCTAssertEqual(alice.stage, .idle, "There is nobody left to play with")
        XCTAssertNil(alice.activeGame)
    }

    func testAForbiddenDataChannelMeansNoPickerAtAll() {
        let (first, _) = LoopbackDataTransport.pair(aliceID, bobID)
        // The room is healthy; the token simply forbids data. A send here
        // would be dropped server-side without erroring, so an invitation
        // would look sent and never arrive.
        first.canSendData = false
        let session = GoPlaySessionModel(
            transport: first,
            localSeat: CallGameSeat(id: aliceID, displayName: "Alice"),
            peerSeat: CallGameSeat(id: bobID, displayName: "Bob"),
            feedback: SilentIcebreakerFeedback()
        )

        session.openPicker()

        XCTAssertFalse(session.isAvailable)
        XCTAssertEqual(session.stage, .idle, "A picker whose invitations vanish is never offered")
    }

    // MARK: - Media is never touched

    /// The load-bearing guarantee of every in-call experience: choosing a
    /// game, playing one, and walking out of one are not media operations.
    /// A room that is left and rejoined is a call that visibly drops.
    func testNothingInTheLobbyOrTheGamesEverJoinsOrLeavesTheRoom() async throws {
        let media = MockCallMediaService()
        let session = CallSession(
            id: "session-abc",
            candidate: DiscoveryCandidate(
                id: bobID, displayName: "Bob", age: 27, city: "Chicago",
                photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .he
            ),
            mode: .video,
            startedAt: Date(),
            maxDuration: CallSession.speedCallDuration
        )
        try await media.join(session: session)
        XCTAssertEqual(media.joinCount, 1)

        let transport = try XCTUnwrap(media.dataTransport)
        let lobby = GoPlaySessionModel(
            transport: transport,
            localSeat: CallGameSeat(id: MockCallMediaService.mockLocalIdentity, displayName: "You"),
            peerSeat: CallGameSeat(id: bobID, displayName: "Bob"),
            feedback: SilentIcebreakerFeedback()
        )
        let icebreakers = DateIcebreakerSessionModel(
            transport: transport,
            sessionID: session.id,
            localSeat: CallGameSeat(id: MockCallMediaService.mockLocalIdentity, displayName: "You"),
            peerSeat: CallGameSeat(id: bobID, displayName: "Bob"),
            schedule: IcebreakerSchedule(cues: [10, 20, 30], summaryAt: 40),
            feedback: SilentIcebreakerFeedback()
        )
        lobby.begin()
        icebreakers.begin()

        // The whole life of a game: open the list, propose, the stand-in
        // partner accepts, play a round, leave.
        lobby.openPicker()
        lobby.propose(.icebreakers)
        // The stand-in answers on a human-ish delay, so wait for it rather
        // than guessing how long that is.
        await waitUntil("the stand-in partner accepts") { lobby.activeGame == .icebreakers }

        icebreakers.startOnDemand(atElapsed: 10)
        XCTAssertNotNil(icebreakers.currentRound, "Choosing Icebreakers must open a prompt")
        icebreakers.choose(0)
        await waitUntil("the round is played out") {
            icebreakers.currentRound?.phase == .revealed
        }

        icebreakers.dismiss()
        lobby.leaveGame()
        await lobby.drainPendingSends()
        await icebreakers.drainPendingSends()
        await settle()

        XCTAssertEqual(media.joinCount, 1, "Nothing about a game may rejoin the room")
        XCTAssertEqual(media.leaveCount, 0, "…and nothing about a game may leave it")
    }

    /// Listening is set up once, not rebuilt on every state change: a feature
    /// that re-subscribes on each transition is one refactor away from doing
    /// the same to the room.
    func testTheTransportIsSubscribedOnceNotPerStateChange() async {
        let (alice, bob, aliceTransport, _) = makePair()
        // `begin` subscribes inside a task, so let it actually happen before
        // taking the reading this test is about.
        await settle()
        let after = aliceTransport.subscriptionCount
        XCTAssertEqual(after, 1, "Listening starts once, when the screen appears")

        alice.openPicker()
        alice.propose(.icebreakers)
        await exchange(alice, bob)
        bob.acceptInvite()
        await exchange(alice, bob)
        alice.leaveGame()
        await exchange(alice, bob)
        alice.begin()

        XCTAssertEqual(
            aliceTransport.subscriptionCount, after,
            "A whole game's worth of transitions must not resubscribe the channel"
        )
    }

    // MARK: - Helpers

    /// Polls until `condition` holds. Fails the test rather than hanging if
    /// it never does.
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 6,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            await settle(50)
        }
        XCTFail("Timed out waiting for \(what)", file: file, line: line)
    }

    private func makeFlow(experience: CallExperience?) -> CallFlowModel {
        let calls = MockCallService(
            searchLatency: .milliseconds(1), connectLatency: .milliseconds(1)
        )
        if let experience {
            return CallFlowModel(
                mode: .video,
                experience: experience,
                calls: calls,
                matches: MockMatchService(latency: .milliseconds(1)),
                safety: MockSafetyService(),
                media: MockCallMediaService(),
                permissions: StubCallPermissions(granted: true),
                onFinished: {}
            )
        }
        return CallFlowModel(
            mode: .video,
            calls: calls,
            matches: MockMatchService(latency: .milliseconds(1)),
            safety: MockSafetyService(),
            media: MockCallMediaService(),
            permissions: StubCallPermissions(granted: true),
            onFinished: {}
        )
    }
}
