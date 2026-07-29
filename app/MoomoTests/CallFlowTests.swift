import XCTest
@testable import Moomo

/// The call state machine: search → connect → live call → clock → end →
/// decision, plus in-call safety actions.
@MainActor
final class CallFlowTests: XCTestCase {

    private var calls: MockCallService!
    private var chat: MockChatService!
    private var notifications: MockNotificationService!
    private var matches: MockMatchService!
    private var safety: MockSafetyService!
    private var finishedCount = 0

    /// The sample data's featured person, by his real id, so the blocking
    /// test exercises the same person the matchmaking pool contains.
    private let kenji = DiscoveryCandidate(
        id: "u-featured", displayName: "Kenji", age: 26, city: "Chicago",
        photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .he
    )

    override func setUp() async throws {
        try await super.setUp()
        finishedCount = 0
        chat = MockChatService(autoReplyDelay: nil)
        notifications = MockNotificationService(seed: [])
        let chat = self.chat!
        let notifications = self.notifications!
        matches = MockMatchService(
            latency: .milliseconds(1),
            onMatch: { match in
                await chat.createConversation(for: match)
                await notifications.add(AppNotification(
                    id: match.id, kind: .match, title: "Match", body: "",
                    sentAt: Date(), isRead: false
                ))
            }
        )
        let matches = self.matches!
        safety = MockSafetyService(onBlock: { userID in
            await matches.removeMatches(with: userID)
            await chat.removeConversations(with: userID)
        })
        calls = MockCallService(
            searchLatency: .milliseconds(1),
            connectLatency: .milliseconds(1),
            isBlocked: { [safety] in await safety!.isBlocked($0) }
        )
    }

    override func tearDown() async throws {
        calls = nil; chat = nil; notifications = nil; matches = nil; safety = nil
        try await super.tearDown()
    }

    private func makeFlow(
        mode: CallMode = .voice,
        preferred: DiscoveryCandidate? = nil,
        incoming: CallInvite? = nil,
        callDuration: TimeInterval = CallSession.speedCallDuration,
        media: MockCallMediaService = MockCallMediaService(),
        permissionsGranted: Bool = true,
        peerJoinTimeout: TimeInterval = 15
    ) -> CallFlowModel {
        CallFlowModel(
            mode: mode,
            preferred: preferred,
            incoming: incoming,
            calls: calls,
            matches: matches,
            safety: safety,
            media: media,
            permissions: StubCallPermissions(granted: permissionsGranted),
            callDuration: callDuration,
            peerJoinTimeout: peerJoinTimeout,
            onFinished: { [weak self] in self?.finishedCount += 1 }
        )
    }

    private func settle(_ ms: UInt64 = 100) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// Runs a flow to the live call.
    private func startedFlow(
        mode: CallMode = .voice,
        callDuration: TimeInterval = CallSession.speedCallDuration,
        media: MockCallMediaService = MockCallMediaService(),
        peerJoinTimeout: TimeInterval = 15
    ) async -> CallFlowModel {
        let flow = makeFlow(
            mode: mode, preferred: kenji, callDuration: callDuration,
            media: media, peerJoinTimeout: peerJoinTimeout
        )
        flow.start()
        await settle(150)
        return flow
    }

    // MARK: - Starting

    func testStartReachesActiveCallWithPreferredCandidate() async throws {
        let flow = await startedFlow()

        guard case .active(let session) = flow.stage else {
            return XCTFail("Expected an active call, got \(flow.stage)")
        }
        XCTAssertEqual(session.candidate.id, kenji.id, "Talk to Him must call the featured person")
        XCTAssertEqual(session.mode, .voice)
        XCTAssertEqual(flow.remainingSeconds, Int(CallSession.speedCallDuration))
    }

    func testCancelDuringSearchFinishesWithoutHistory() async {
        calls = MockCallService(searchLatency: .seconds(5), connectLatency: .milliseconds(1))
        let flow = makeFlow()
        flow.start()
        await settle(30)

        flow.cancel()
        await settle(50)

        XCTAssertEqual(finishedCount, 1, "Cancelling the search must finish the flow")
        let history = await calls.history()
        XCTAssertTrue(history.isEmpty, "A call that never connected is not history")
    }

    // MARK: - Incoming rings

    private func incomingInvite(mode: CallMode = .video) -> CallInvite {
        CallInvite(
            id: kenji.id, caller: kenji, mode: mode,
            expiresAt: Date().addingTimeInterval(10)
        )
    }

    func testAcceptedRingSkipsSearchAndReachesActive() async {
        let flow = makeFlow(mode: .video, incoming: incomingInvite())
        flow.start()

        guard case .connecting(let caller) = flow.stage else {
            return XCTFail("An accepted ring must show who is calling immediately, got \(flow.stage)")
        }
        XCTAssertEqual(caller.id, kenji.id)

        await settle(150)

        guard case .active(let session) = flow.stage else {
            return XCTFail("Expected an active call, got \(flow.stage)")
        }
        XCTAssertEqual(session.candidate.id, kenji.id, "the call is with the caller")
        XCTAssertEqual(session.mode, .video, "the ring's mode is the call's mode")
    }

    func testUnavailableRingFailsWithTheFriendlyMessage() async {
        // A blocked caller stands in for every lost accept — someone faster,
        // an expired ring, a caller who left. All answer "unavailable".
        calls = MockCallService(
            searchLatency: .milliseconds(1),
            connectLatency: .milliseconds(1),
            isBlocked: { $0 == "u-featured" }
        )
        let flow = makeFlow(mode: .video, incoming: incomingInvite())
        flow.start()
        await settle(150)

        guard case .failed(let failure) = flow.stage else {
            return XCTFail("Expected the lost-ring failure, got \(flow.stage)")
        }
        XCTAssertEqual(failure.message, CallServiceError.inviteUnavailable.errorDescription)
        XCTAssertFalse(failure.isPermissionDenied)

        let history = await calls.history()
        XCTAssertTrue(history.isEmpty, "a ring we lost never became a call")
    }

    func testIncomingRingRespectsThePermissionGate() async {
        let flow = makeFlow(
            mode: .video, incoming: incomingInvite(), permissionsGranted: false
        )
        flow.start()
        await settle(100)

        guard case .failed(let failure) = flow.stage else {
            return XCTFail("Expected a permission failure, got \(flow.stage)")
        }
        XCTAssertTrue(failure.isPermissionDenied, "the failure must point at Settings")
        let history = await calls.history()
        XCTAssertTrue(history.isEmpty, "no accepting a call the microphone can't join")
    }

    // MARK: - Empty room

    func testNobodyJoiningEndsOnTheFailureScreenNotTheDecision() async {
        let flow = await startedFlow(
            media: MockCallMediaService(peerJoins: false),
            peerJoinTimeout: 0.05
        )
        await settle(200)

        guard case .failed(let failure) = flow.stage else {
            return XCTFail("An empty room must end on the failure screen, got \(flow.stage)")
        }
        XCTAssertTrue(failure.message.contains("couldn't make it"), failure.message)

        let history = await calls.history()
        XCTAssertEqual(history.count, 1, "the server session is closed, not abandoned")
        XCTAssertEqual(history.first?.endReason, .ended)
        XCTAssertEqual(history.first?.outcome, .undecided)
    }

    func testPeerPresenceDisarmsTheEmptyRoomBailOut() async {
        let flow = await startedFlow(
            media: MockCallMediaService(), // the pretend peer joins immediately
            peerJoinTimeout: 0.05
        )
        await settle(200)

        guard case .active = flow.stage else {
            return XCTFail("A call with a present peer must keep running, got \(flow.stage)")
        }
    }

    func testLateArrivalWithinTheGraceKeepsTheCall() async {
        let media = MockCallMediaService(peerJoins: false)
        let flow = await startedFlow(media: media, peerJoinTimeout: 0.6)

        media.simulatePeerJoined() // ~150ms in — inside the grace window
        await settle(700)

        guard case .active = flow.stage else {
            return XCTFail("A peer arriving within the grace must keep the call, got \(flow.stage)")
        }
    }

    // MARK: - Ending

    func testEndCallMovesToDecisionAndRecordsHistory() async throws {
        let flow = await startedFlow()

        flow.endCall()
        await settle()

        guard case .deciding(let summary) = flow.stage else {
            return XCTFail("Expected the decision screen, got \(flow.stage)")
        }
        XCTAssertEqual(summary.candidate.id, kenji.id)
        XCTAssertEqual(summary.endReason, .ended)

        let history = await calls.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].outcome, .undecided, "The decision hasn't been made yet")
        XCTAssertEqual(history[0].candidate.id, kenji.id)
    }

    func testClockExpiryEndsTheCall() async throws {
        let flow = await startedFlow(callDuration: 1)

        // One 1-second tick plus scheduling slack.
        await settle(1600)

        guard case .deciding(let summary) = flow.stage else {
            return XCTFail("Expected the clock to end the call, got \(flow.stage)")
        }
        XCTAssertEqual(summary.endReason, .timeExpired)
    }

    func testMuteAndCameraToggles() async {
        let voice = await startedFlow(mode: .voice)
        XCTAssertFalse(voice.isCameraOn, "Voice calls have no camera")
        XCTAssertFalse(voice.isMuted)
        voice.toggleMute()
        XCTAssertTrue(voice.isMuted)
        voice.endCall()

        let video = await startedFlow(mode: .video)
        XCTAssertTrue(video.isCameraOn, "Video calls start with the camera on")
        video.toggleCamera()
        XCTAssertFalse(video.isCameraOn)
    }

    // MARK: - Permissions & media

    func testDeniedPermissionFailsBeforeSearching() async {
        let flow = makeFlow(permissionsGranted: false)
        flow.start()
        await settle(100)

        guard case .failed(let failure) = flow.stage else {
            return XCTFail("Expected a permission failure, got \(flow.stage)")
        }
        XCTAssertTrue(failure.isPermissionDenied, "The failure must point at Settings")
        let history = await calls.history()
        XCTAssertTrue(history.isEmpty, "No matchmaking without a working microphone")
    }

    func testMediaJoinFailureFailsTheFlowAndEndsTheSession() async {
        let flow = makeFlow(
            preferred: kenji,
            media: MockCallMediaService(joinError: .connectFailed)
        )
        flow.start()
        await settle(200)

        guard case .failed(let failure) = flow.stage else {
            return XCTFail("Expected a media failure, got \(flow.stage)")
        }
        XCTAssertFalse(failure.isPermissionDenied)

        let history = await calls.history()
        XCTAssertEqual(history.count, 1, "The server session must be ended, not abandoned")
        XCTAssertEqual(history[0].endReason, .ended)
    }

    func testPeerEndingTheCallMovesToDeciding() async throws {
        let flow = await startedFlow()
        guard case .active(let session) = flow.stage else {
            return XCTFail("Expected an active call, got \(flow.stage)")
        }

        calls.simulatePeerEnded(sessionID: session.id)
        await settle(100)

        guard case .deciding(let summary) = flow.stage else {
            return XCTFail("Expected the decision screen, got \(flow.stage)")
        }
        XCTAssertEqual(summary.endReason, .ended)
        XCTAssertEqual(summary.recordID, session.id)

        let history = await calls.history()
        XCTAssertTrue(
            history.isEmpty,
            "The server already ended the session and wrote history — no duplicate end"
        )
    }

    func testTransportLossEndsTheCall() async throws {
        let media = MockCallMediaService()
        let flow = await startedFlow(media: media)
        guard case .active = flow.stage else {
            return XCTFail("Expected an active call, got \(flow.stage)")
        }

        media.simulateTransportLost()
        await settle(100)

        guard case .deciding(let summary) = flow.stage else {
            return XCTFail("A dead transport must end the call, got \(flow.stage)")
        }
        XCTAssertEqual(summary.endReason, .ended)
        let history = await calls.history()
        XCTAssertEqual(history.count, 1, "A transport-loss end is still an end — the session must close")
    }

    func testFailedControlChangeRevertsTheToggle() async {
        let flow = await startedFlow(media: MockCallMediaService(controlsFail: true))

        flow.toggleMute()
        XCTAssertTrue(flow.isMuted, "Optimistic flip while the change is in flight")
        await settle(100)

        XCTAssertFalse(flow.isMuted, "The button must not claim a state the microphone isn't in")
        XCTAssertNotNil(flow.actionFailure)
    }

    // MARK: - Decisions

    func testPassCreatesNothingAndFinishes() async throws {
        let flow = await startedFlow()
        flow.endCall()

        await flow.decide(.pass)

        XCTAssertEqual(finishedCount, 1, "Passing ends the flow")
        let matchList = await matches.matches()
        XCTAssertTrue(matchList.isEmpty)
        let history = await calls.history()
        XCTAssertEqual(history[0].outcome, .passed)
    }

    func testMutualLikeCreatesMatchConversationAndNotification() async throws {
        // Kenji wants to talk, so the simulated peer always likes back.
        let flow = await startedFlow()
        flow.endCall()

        await flow.decide(.like)

        guard case .matched(let match) = flow.stage else {
            return XCTFail("Expected a match, got \(flow.stage)")
        }
        XCTAssertEqual(match.candidate.id, kenji.id)

        let matchList = await matches.matches()
        XCTAssertEqual(matchList.count, 1)

        let conversations = await chat.conversations()
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(
            conversations[0].id, match.conversationID,
            "The match's conversation must exist the moment the match does"
        )

        let notes = await notifications.notifications()
        XCTAssertEqual(notes.count, 1, "A match announces itself")

        let history = await calls.history()
        XCTAssertEqual(history[0].outcome, .matched)
    }

    func testUnreciprocatedLikeIsHonestAboutIt() async throws {
        let loner = DiscoveryCandidate(
            id: "u-1", displayName: "Anaya", age: 24, city: "Chicago",
            photoPath: nil, isOnline: true, wantsToTalk: false, pronoun: .she
        )
        // Force the peer to pass, whatever the hash says.
        matches = MockMatchService(latency: .milliseconds(1), peerDecision: { _ in .pass })
        let flow = makeFlow(preferred: loner)
        flow.start()
        await settle(150)
        flow.endCall()

        await flow.decide(.like)

        guard case .likeSent = flow.stage else {
            return XCTFail("Expected likeSent, got \(flow.stage)")
        }
        let matchList = await matches.matches()
        XCTAssertTrue(matchList.isEmpty, "One-sided likes must never match")
        let history = await calls.history()
        XCTAssertEqual(history[0].outcome, .liked)
    }

    // MARK: - Safety

    func testBlockDuringCallEndsEverything() async throws {
        let flow = await startedFlow()

        await flow.blockAndFinish()

        XCTAssertEqual(finishedCount, 1, "Blocking ends the flow — nothing to decide")
        let blocked = await safety.blockedUsers()
        XCTAssertEqual(blocked.map(\.userID), [kenji.id])

        let history = await calls.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].endReason, .blocked)
        XCTAssertEqual(history[0].outcome, .blocked)

        // And matchmaking can never hand them back.
        let next = try await calls.findCandidate(mode: .voice, preferring: kenji)
        XCTAssertNotEqual(next.id, kenji.id, "A blocked person must not be re-matched")
    }

    func testReportIsRecorded() async throws {
        let flow = await startedFlow()

        await flow.submitReport(reason: .harassment, details: "test details")

        XCTAssertTrue(flow.didSubmitReport)
        let reports = await safety.reports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].reportedUserID, kenji.id)
        XCTAssertEqual(reports[0].reason, .harassment)
        XCTAssertEqual(reports[0].details, "test details")

        // Reporting alone does not end the call — that's the user's choice.
        if case .active = flow.stage {} else {
            XCTFail("The call should still be running after a report")
        }
    }
}
