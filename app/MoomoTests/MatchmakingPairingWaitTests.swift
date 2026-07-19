import XCTest
@testable import Moomo

/// The queue-wait race in `MatchmakingPairingWait`. The edge that matters:
/// the backend's pairing write landing in the same instant the timeout fires
/// must be recovered by the final check — a search that gives up then leaves
/// its peer in a call with nobody on the other side.
final class MatchmakingPairingWaitTests: XCTestCase {

    func testMatchedEventWinsBeforeTimeout() async throws {
        let sessionID = try await MatchmakingPairingWait.session(
            matchedSessionIDs: AsyncStream { continuation in
                continuation.yield("session-1")
                continuation.finish()
            },
            timeout: .seconds(5)
        ) {
            XCTFail("no final check when the listener already delivered")
            return nil
        }
        XCTAssertEqual(sessionID, "session-1")
    }

    func testTimeoutWithNoPairingThrowsNoOneAvailable() async {
        do {
            _ = try await MatchmakingPairingWait.session(
                matchedSessionIDs: AsyncStream { _ in }, // never yields
                timeout: .milliseconds(20)
            ) { nil }
            XCTFail("expected noOneAvailable")
        } catch {
            XCTAssertEqual(error as? CallServiceError, .noOneAvailable)
        }
    }

    func testPairingLandingExactlyAtTimeoutIsRecovered() async throws {
        // The listener never fires (cancelled in the same instant the server
        // paired us); the final authoritative read finds the session.
        let sessionID = try await MatchmakingPairingWait.session(
            matchedSessionIDs: AsyncStream { _ in },
            timeout: .milliseconds(20)
        ) { "session-raced" }
        XCTAssertEqual(sessionID, "session-raced")
    }

    func testDeadStreamStillGetsTheFinalCheck() async throws {
        // A snapshot stream dying is not proof there was no pairing.
        let sessionID = try await MatchmakingPairingWait.session(
            matchedSessionIDs: AsyncStream { $0.finish() },
            timeout: .seconds(5)
        ) { "session-after-dead-stream" }
        XCTAssertEqual(sessionID, "session-after-dead-stream")
    }

    // MARK: - Snapshot acceptance

    func testCachedMatchedSnapshotIsIgnored() {
        XCTAssertNil(
            MatchmakingPairingWait.matchedSessionID(
                status: "matched", sessionID: "session-old", isFromCache: true
            ),
            "a cache replay of a previous search's matched state must not be trusted"
        )
    }

    func testServerMatchedSnapshotIsAccepted() {
        XCTAssertEqual(
            MatchmakingPairingWait.matchedSessionID(
                status: "matched", sessionID: "session-1", isFromCache: false
            ),
            "session-1"
        )
    }

    func testNonMatchedOrMalformedSnapshotsAreNotPairings() {
        XCTAssertNil(MatchmakingPairingWait.matchedSessionID(
            status: "waiting", sessionID: nil, isFromCache: false
        ))
        XCTAssertNil(
            MatchmakingPairingWait.matchedSessionID(
                status: "matched", sessionID: nil, isFromCache: false
            ),
            "matched without a sessionId is malformed, not a pairing"
        )
    }

    func testCancelledSearchNeverAdoptsASession() async {
        let search = Task {
            try await MatchmakingPairingWait.session(
                matchedSessionIDs: AsyncStream { _ in },
                timeout: .seconds(60)
            ) {
                XCTFail("a cancelled search must not adopt a session")
                return "session-x"
            }
        }
        search.cancel()

        do {
            _ = try await search.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }
}
