import XCTest
@testable import Moomo

/// The client half of the presence-hotspot fix (audit P1-1): the heartbeat
/// throttle, the quantized activity bucket the rules verify, and the feed
/// payload decoding that replaced the raw `publicProfiles` query (P0-3).
final class DiscoveryPresenceTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_721_500_123)

    // MARK: - Throttle policy

    func testFirstHeartbeatAlwaysSends() {
        XCTAssertTrue(PresenceHeartbeat.shouldSend(lastSentAt: nil, now: epoch))
    }

    func testHeartbeatInsideTheIntervalIsSuppressed() {
        let justSent = epoch.addingTimeInterval(-(PresenceHeartbeat.minimumInterval - 1))
        XCTAssertFalse(PresenceHeartbeat.shouldSend(lastSentAt: justSent, now: epoch))
    }

    func testHeartbeatAtTheIntervalSendsAgain() {
        let intervalAgo = epoch.addingTimeInterval(-PresenceHeartbeat.minimumInterval)
        XCTAssertTrue(PresenceHeartbeat.shouldSend(lastSentAt: intervalAgo, now: epoch))
    }

    func testThrottleStaysInsideTheOnlineWindow() {
        // A continuously active user heartbeats often enough to never
        // flicker offline: the throttle must undercut the online window.
        XCTAssertLessThan(PresenceHeartbeat.minimumInterval, 5 * 60)
    }

    func testTrackerRecordsSendsPerUser() {
        let tracker = PresenceHeartbeatTracker()

        XCTAssertTrue(tracker.markSendable(uid: "alice", now: epoch), "first send goes out")
        XCTAssertFalse(
            tracker.markSendable(uid: "alice", now: epoch.addingTimeInterval(1)),
            "an immediate reopen is throttled"
        )
        XCTAssertTrue(
            tracker.markSendable(uid: "bob", now: epoch.addingTimeInterval(1)),
            "the throttle is per user, not global"
        )
        XCTAssertTrue(
            tracker.markSendable(
                uid: "alice",
                now: epoch.addingTimeInterval(PresenceHeartbeat.minimumInterval)
            ),
            "after the interval the heartbeat resumes"
        )
    }

    // MARK: - Activity bucket (must satisfy activityBucketIsHonest in rules)

    func testBucketIsAlignedToTenMinutes() {
        let bucket = PresenceHeartbeat.activityBucket(for: epoch)
        XCTAssertEqual(
            bucket.timeIntervalSince1970
                .truncatingRemainder(dividingBy: PresenceHeartbeat.bucketInterval),
            0,
            "rules reject any bucket not aligned to 600s"
        )
    }

    func testBucketIsTheFloorOfNow() {
        let bucket = PresenceHeartbeat.activityBucket(for: epoch)
        XCTAssertLessThanOrEqual(bucket, epoch, "never from the future")
        XCTAssertLessThan(
            epoch.timeIntervalSince(bucket),
            PresenceHeartbeat.bucketInterval,
            "never more than one bucket behind"
        )
    }

    func testAnAlreadyAlignedInstantIsItsOwnBucket() {
        let aligned = Date(timeIntervalSince1970: 1_721_499_600)
        XCTAssertEqual(PresenceHeartbeat.activityBucket(for: aligned), aligned)
    }

    // MARK: - Feed decoding

    private func row(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = [
            "uid": "kenji-uid",
            "displayName": "Kenji",
            "age": 29,
            "city": "Osaka",
            "occupation": "Chef",
            "photoPath": "users/kenji-uid/photos/p1.jpg",
            "gender": "man",
            "isOnline": true,
            "wantsToTalk": true,
            "isVerified": false,
        ]
        for (key, value) in overrides { row[key] = value }
        return row
    }

    func testDecodesTheFullCandidate() throws {
        let candidates = DiscoveryFeedDecoding.candidates(
            fromFeedPayload: ["candidates": [row()]]
        )
        let kenji = try XCTUnwrap(candidates.first)

        XCTAssertEqual(kenji.id, "kenji-uid")
        XCTAssertEqual(kenji.displayName, "Kenji")
        XCTAssertEqual(kenji.age, 29)
        XCTAssertEqual(kenji.city, "Osaka")
        XCTAssertEqual(kenji.occupation, "Chef")
        XCTAssertEqual(kenji.photoPath, "users/kenji-uid/photos/p1.jpg")
        XCTAssertTrue(kenji.isOnline)
        XCTAssertTrue(kenji.wantsToTalk)
        XCTAssertFalse(kenji.isVerified)
        XCTAssertEqual(kenji.pronoun, .he)
    }

    func testMissingOptionalsDecodeToHonestDefaults() throws {
        let sparse: [String: Any] = ["uid": "ana-uid", "displayName": "Ana"]
        let candidate = try XCTUnwrap(
            DiscoveryFeedDecoding.candidate(fromRow: sparse)
        )

        XCTAssertEqual(candidate.age, 0)
        XCTAssertEqual(candidate.city, "")
        XCTAssertNil(candidate.occupation)
        XCTAssertNil(candidate.photoPath)
        XCTAssertFalse(candidate.isOnline, "unknown presence must not claim online")
        XCTAssertFalse(candidate.wantsToTalk)
        XCTAssertEqual(candidate.pronoun, .they, "unknown gender stays neutral")
    }

    func testEmptyStringsCollapseToNil() throws {
        let candidate = try XCTUnwrap(
            DiscoveryFeedDecoding.candidate(fromRow: row(["occupation": "", "photoPath": ""]))
        )
        XCTAssertNil(candidate.occupation)
        XCTAssertNil(candidate.photoPath)
    }

    func testRowsWithoutIdentityOrNameAreDropped() {
        XCTAssertNil(DiscoveryFeedDecoding.candidate(fromRow: row(["uid": ""])))
        XCTAssertNil(DiscoveryFeedDecoding.candidate(fromRow: row(["displayName": ""])))
        var nameless = row(); nameless.removeValue(forKey: "displayName")
        XCTAssertNil(DiscoveryFeedDecoding.candidate(fromRow: nameless))
    }

    func testJunkPayloadsDecodeToEmptyNotACrash() {
        XCTAssertEqual(DiscoveryFeedDecoding.candidates(fromFeedPayload: nil), [])
        XCTAssertEqual(DiscoveryFeedDecoding.candidates(fromFeedPayload: "nope"), [])
        XCTAssertEqual(DiscoveryFeedDecoding.candidates(fromFeedPayload: ["candidates": "nope"]), [])
        XCTAssertEqual(
            DiscoveryFeedDecoding.candidates(fromFeedPayload: ["wrongKey": [row()]]),
            []
        )
    }

    func testPronounFollowsGenderWithNeutralDefault() {
        XCTAssertEqual(CandidatePronoun(genderRawValue: "man"), .he)
        XCTAssertEqual(CandidatePronoun(genderRawValue: "woman"), .she)
        XCTAssertEqual(CandidatePronoun(genderRawValue: "nonBinary"), .they)
        XCTAssertEqual(CandidatePronoun(genderRawValue: nil), .they)
    }
}
