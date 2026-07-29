import XCTest
@testable import Moomo

/// The incoming-ring gate in `CallInviteLogic`, plus the mock service's
/// invite surface. The edges that matter mirror the pairing wait's: a cache
/// replay of an old ring must never raise the banner, a terminal or expired
/// invite is nothing, and a blocked pair loses the accept exactly like a
/// lost race — never like a block.
@MainActor
final class CallInviteLogicTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_753_200_000)

    private func settle(_ ms: UInt64 = 100) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    private func callerSummary(
        displayName: String = "Kenji",
        photoPath: String? = "photos/u-caller/0.jpg"
    ) -> [String: Any] {
        var summary: [String: Any] = [
            "uid": "u-caller",
            "displayName": displayName,
            "age": 26,
            "city": "Chicago",
            "gender": "man",
            "isVerified": true,
        ]
        if let photoPath { summary["photoPath"] = photoPath }
        return summary
    }

    private func decode(
        callerUid: String? = "u-caller",
        caller: [String: Any]? = nil,
        mode: String? = "video",
        status: String? = "ringing",
        expiresAt: Date? = nil,
        isFromCache: Bool = false
    ) -> CallInvite? {
        CallInviteLogic.invite(
            callerUid: callerUid,
            caller: caller ?? callerSummary(),
            mode: mode,
            status: status,
            expiresAt: expiresAt ?? now.addingTimeInterval(10),
            isFromCache: isFromCache,
            now: now
        )
    }

    // MARK: - Decoding

    func testDecodesRingingInvite() throws {
        let invite = try XCTUnwrap(decode())

        XCTAssertEqual(invite.id, "u-caller", "the invite is identified by who is ringing")
        XCTAssertEqual(invite.caller.id, "u-caller")
        XCTAssertEqual(invite.caller.displayName, "Kenji")
        XCTAssertEqual(invite.caller.age, 26)
        XCTAssertEqual(invite.caller.city, "Chicago")
        XCTAssertEqual(invite.caller.photoPath, "photos/u-caller/0.jpg")
        XCTAssertTrue(invite.caller.isVerified)
        XCTAssertEqual(invite.caller.pronoun, .he)
        XCTAssertEqual(invite.mode, .video)
        XCTAssertEqual(invite.expiresAt, now.addingTimeInterval(10))
        XCTAssertFalse(
            invite.caller.isOnline,
            "a fan-out summary is a snapshot and must not claim presence"
        )
    }

    func testSparseCallerSummaryStillRings() throws {
        // A summary missing fields renders placeholders rather than dropping
        // the ring — same tolerance as SocialDecoding's participant decode.
        let sparse = try XCTUnwrap(CallInviteLogic.invite(
            callerUid: "u-caller",
            caller: [:],
            mode: "voice",
            status: "ringing",
            expiresAt: now.addingTimeInterval(5),
            isFromCache: false,
            now: now
        ))
        XCTAssertEqual(sparse.caller.displayName, "Someone")
        XCTAssertEqual(sparse.caller.pronoun, .they)
        XCTAssertFalse(sparse.caller.isVerified)
        XCTAssertNil(sparse.caller.photoPath)
        XCTAssertEqual(sparse.mode, .voice)
    }

    func testRejectsCacheSnapshots() {
        XCTAssertNil(
            decode(isFromCache: true),
            "a cache replay of an old ring must never raise the banner"
        )
    }

    func testRejectsNonRingingStatuses() {
        for status in ["accepted", "declined", "cancelled", "expired"] {
            XCTAssertNil(decode(status: status), "'\(status)' is terminal, not a ring")
        }
        XCTAssertNil(decode(status: nil))
    }

    func testRejectsExpiredInvite() {
        XCTAssertNil(decode(expiresAt: now), "expiry is exclusive — expired means gone")
        XCTAssertNil(decode(expiresAt: now.addingTimeInterval(-1)))
    }

    func testRejectsMalformedDocuments() {
        XCTAssertNil(decode(callerUid: nil), "no caller, no ring")
        XCTAssertNil(decode(callerUid: ""))
        XCTAssertNil(decode(mode: nil))
        XCTAssertNil(decode(mode: "hologram"), "an unknown mode must not default to a call type")
        XCTAssertNil(CallInviteLogic.invite(
            callerUid: "u-caller",
            caller: callerSummary(),
            mode: "video",
            status: "ringing",
            expiresAt: nil,
            isFromCache: false,
            now: now
        ), "an invite without a deadline cannot be trusted to be live")
    }

    func testBannerDurationStaysUnderTheServerAcceptanceWindow() {
        // RING_TTL_MS is 10s server-side. The banner must come down before
        // the server would refuse the accept — same client-under-server
        // pattern as searchTimeout (30s) vs QUEUE_ENTRY_TTL_MS (40s).
        XCTAssertEqual(CallInvite.ringSeconds, 7)
        XCTAssertLessThan(CallInvite.ringSeconds, 10)
    }

    // MARK: - Mock service parity

    private let kenji = DiscoveryCandidate(
        id: "u-featured", displayName: "Kenji", age: 26, city: "Chicago",
        photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .he
    )

    func testMockStreamsInviteAndWithdrawal() async {
        let calls = MockCallService()
        var received: [CallInvite?] = []
        let collector = Task {
            for await invite in calls.incomingInvites() {
                received.append(invite)
            }
        }
        await settle()

        let invite = calls.simulateIncomingInvite(caller: kenji, mode: .video)
        await settle()
        calls.simulateInviteWithdrawn()
        await settle()

        XCTAssertEqual(
            received, [nil, invite, nil],
            "the stream opens silent, rings, and comes back down on withdrawal"
        )
        collector.cancel()
    }

    func testMockAcceptReturnsTheCallerAndConsumesTheRing() async throws {
        let calls = MockCallService()
        let invite = calls.simulateIncomingInvite(caller: kenji, mode: .voice)

        let caller = try await calls.acceptInvite(invite)

        XCTAssertEqual(caller, kenji)
        var latest: CallInvite??
        for await value in calls.incomingInvites() {
            latest = value
            break
        }
        XCTAssertEqual(latest, .some(nil), "an answered ring is consumed")

        // The accepted caller must connect through the existing path.
        let session = try await calls.connect(to: caller, mode: .voice)
        XCTAssertEqual(session.candidate, kenji)
    }

    func testMockAcceptAgainstBlockedCallerIsUnavailable() async {
        let calls = MockCallService(isBlocked: { $0 == "u-featured" })
        let invite = calls.simulateIncomingInvite(caller: kenji, mode: .video)

        do {
            _ = try await calls.acceptInvite(invite)
            XCTFail("a blocked pair must not connect")
        } catch {
            XCTAssertEqual(
                error as? CallServiceError, .inviteUnavailable,
                "blocked must be indistinguishable from a lost race"
            )
        }
    }

    func testMockDeclineIsRecordedAndConsumesTheRing() async {
        let calls = MockCallService()
        let invite = calls.simulateIncomingInvite(caller: kenji, mode: .video)

        await calls.declineInvite(invite)

        XCTAssertEqual(calls.declinedInvites, [invite])
        var latest: CallInvite??
        for await value in calls.incomingInvites() {
            latest = value
            break
        }
        XCTAssertEqual(latest, .some(nil), "a declined ring is consumed")
    }
}
