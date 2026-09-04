import XCTest
@testable import Moomo

/// The banner state machine behind the incoming-call card: a ring raises it,
/// answer/decline/withdrawal/timeout take it down, and the auto-dismiss clock
/// respects both the product window and the server's acceptance deadline.
@MainActor
final class IncomingCallModelTests: XCTestCase {

    private let kenji = DiscoveryCandidate(
        id: "u-featured", displayName: "Kenji", age: 26, city: "Chicago",
        photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .he
    )

    private func settle(_ ms: UInt64 = 100) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    func testRingFromTheStreamRaisesTheBanner() async {
        let calls = MockCallService()
        let model = IncomingCallModel(calls: calls)
        await settle()
        XCTAssertNil(model.invite, "silence at start — the stream opens with nil")

        let invite = calls.simulateIncomingInvite(caller: kenji, mode: .video)
        await settle()

        XCTAssertEqual(model.invite, invite)
    }

    func testBannerAutoDismissesAfterRingSeconds() async {
        let calls = MockCallService()
        let model = IncomingCallModel(calls: calls, ringSeconds: 0.15)
        await settle(50)

        calls.simulateIncomingInvite(caller: kenji, mode: .video)
        await settle(60)
        XCTAssertNotNil(model.invite, "still inside the ring window")

        await settle(300)
        XCTAssertNil(model.invite, "an unanswered ring times out on its own")
    }

    func testBannerComesDownAtTheServerDeadlineWhenItIsSooner() async {
        let calls = MockCallService()
        // Product window 5s, but the server's acceptance deadline is ~150ms
        // out — the stricter clock must win, or the banner would offer an
        // accept the server refuses.
        let model = IncomingCallModel(calls: calls, ringSeconds: 5)
        await settle(50)

        calls.simulateIncomingInvite(
            caller: kenji, mode: .video,
            expiresAt: Date().addingTimeInterval(0.15)
        )
        await settle(400)

        XCTAssertNil(model.invite)
    }

    func testDeclineClearsImmediatelyAndReachesTheService() async {
        let calls = MockCallService()
        let model = IncomingCallModel(calls: calls)
        await settle(50)
        let invite = calls.simulateIncomingInvite(caller: kenji, mode: .video)
        await settle()

        model.decline()

        XCTAssertNil(model.invite, "the banner never waits on the network to come down")
        await settle()
        XCTAssertEqual(calls.declinedInvites, [invite], "the decline is best-effort but real")
    }

    func testAcceptClearsAndHandsTheInviteOut() async {
        let calls = MockCallService()
        let model = IncomingCallModel(calls: calls)
        await settle(50)
        let invite = calls.simulateIncomingInvite(caller: kenji, mode: .video)
        await settle()

        let handed = model.accept()

        XCTAssertEqual(handed, invite, "accept hands the ring to the coordinator")
        XCTAssertNil(model.invite)
        XCTAssertTrue(
            calls.declinedInvites.isEmpty,
            "accepting is not declining — the flow runs the accept callable itself"
        )
    }

    /// Speed Talk is gone. A ring from a client that predates its removal is
    /// not something this app can answer, so it is turned away for the caller
    /// rather than shown as an "Incoming Voice Call" whose accept leads
    /// nowhere.
    func testAVoiceOnlyRingIsDeclinedRatherThanShown() async {
        let calls = MockCallService()
        let model = IncomingCallModel(calls: calls)
        await settle(50)

        let invite = calls.simulateIncomingInvite(caller: kenji, mode: .voice)
        await settle()

        XCTAssertNil(model.invite, "a retired-mode ring must never raise the banner")
        XCTAssertEqual(
            calls.declinedInvites, [invite],
            "the caller is told, so their fan-out moves on instead of waiting"
        )
    }

    func testAVideoRingStillRingsAfterTheVoiceModeWasRetired() async {
        let calls = MockCallService()
        let model = IncomingCallModel(calls: calls)
        await settle(50)

        let invite = calls.simulateIncomingInvite(caller: kenji, mode: .video)
        await settle()

        XCTAssertEqual(model.invite, invite)
        XCTAssertTrue(calls.declinedInvites.isEmpty)
    }

    func testAcceptWithNoRingHandsNothingOut() async {
        let calls = MockCallService()
        let model = IncomingCallModel(calls: calls)
        await settle(50)

        XCTAssertNil(model.accept(), "a ring that vanished under the tap answers nothing")
    }

    func testWithdrawnInviteTakesTheBannerDown() async {
        let calls = MockCallService()
        let model = IncomingCallModel(calls: calls)
        await settle(50)
        calls.simulateIncomingInvite(caller: kenji, mode: .video)
        await settle()
        XCTAssertNotNil(model.invite)

        calls.simulateInviteWithdrawn()
        await settle()

        XCTAssertNil(model.invite, "cancelled/expired/answered-elsewhere rings come down")
    }
}
