import Foundation

/// The client half of the presence-hotspot fix (production-readiness audit
/// P1-1), pure Foundation so it is unit-testable without Firebase.
///
/// Discover used to write an indexed `lastActiveAt = serverTimestamp()` on
/// EVERY screen open — a monotonically increasing indexed value, which is
/// Firestore's documented write-hotspot anti-pattern (~500 sequential
/// writes/s per index). Two changes, both here:
///
///  1. THROTTLE — at most one heartbeat per `minimumInterval` per user,
///     enforced in-process by `PresenceHeartbeatTracker`. The interval sits
///     just under the five-minute online window, so a continuously active
///     user never flickers offline.
///  2. QUANTIZE — the heartbeat also writes `activityBucket`, `lastActiveAt`
///     floored to a ten-minute bucket. The backend feed orders by the bucket
///     (whose index keys are shared, not sequential); the exact
///     `lastActiveAt` stays on the document for the online dot but is no
///     longer indexed. Rules (`activityBucketIsHonest`) verify alignment and
///     nearness to server time, so a tampered client cannot sit atop
///     Discover from the future.
enum PresenceHeartbeat {

    /// Minimum gap between presence writes. Under the five-minute
    /// `FirestoreDiscoveryService.onlineWindow`, so throttling never makes
    /// an active user look offline.
    static let minimumInterval: TimeInterval = 4 * 60

    /// Must equal the rules' bucket size (600,000 ms) and the backend's
    /// ordering granularity — see `activityBucketIsHonest` in
    /// backend/firestore.rules.
    static let bucketInterval: TimeInterval = 10 * 60

    static func shouldSend(lastSentAt: Date?, now: Date) -> Bool {
        guard let lastSentAt else { return true }
        return now.timeIntervalSince(lastSentAt) >= minimumInterval
    }

    /// `now` floored to the bucket — aligned exactly the way the rules
    /// verify (`toMillis() % 600000 == 0`, within clock skew of server now).
    static func activityBucket(for now: Date = Date()) -> Date {
        let flooredSeconds =
            (now.timeIntervalSince1970 / bucketInterval).rounded(.down) * bucketInterval
        return Date(timeIntervalSince1970: flooredSeconds)
    }
}

/// Process-lifetime heartbeat bookkeeping. Lives outside the service struct
/// so rebuilding the service graph (tab switches, new Discover models)
/// cannot reset the throttle.
final class PresenceHeartbeatTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSentByUid: [String: Date] = [:]

    /// True exactly when a heartbeat should go out now — and records it, so
    /// the next `minimumInterval` of calls answer false. Recorded even if
    /// the caller's write then fails: presence is best-effort, and when the
    /// write can't land the feed request right behind it is failing anyway.
    func markSendable(uid: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard PresenceHeartbeat.shouldSend(lastSentAt: lastSentByUid[uid], now: now) else {
            return false
        }
        lastSentByUid[uid] = now
        return true
    }
}

extension CandidatePronoun {
    /// Renders "Talk to Him/Her/Them". `they` whenever we don't know — a
    /// wrong guess misgenders someone; the neutral default never does.
    init(genderRawValue: String?) {
        switch genderRawValue {
        case Gender.man.rawValue: self = .he
        case Gender.woman.rawValue: self = .she
        default: self = .they
        }
    }
}

/// Decodes the `getDiscoveryFeed` callable's payload. Hand-decoded like the
/// rest of the wire layer (`SocialDecoding`): the wire shape and the model
/// stay free to diverge without a migration. The backend sends exactly what
/// Discover renders — notably `isOnline` instead of a raw `lastActiveAt`,
/// so precise activity times never reach (or leak from) the client.
enum DiscoveryFeedDecoding {

    static func candidates(fromFeedPayload payload: Any?) -> [DiscoveryCandidate] {
        guard let root = payload as? [String: Any],
              let rows = root["candidates"] as? [[String: Any]] else { return [] }
        return rows.compactMap(candidate(fromRow:))
    }

    static func candidate(fromRow row: [String: Any]) -> DiscoveryCandidate? {
        // The backend never sends unnamed profiles; the guard is parity with
        // the old client filter, kept so a decoding gap can't render "".
        guard let id = row["uid"] as? String, !id.isEmpty,
              let displayName = row["displayName"] as? String, !displayName.isEmpty
        else { return nil }
        let occupation = row["occupation"] as? String
        return DiscoveryCandidate(
            id: id,
            displayName: displayName,
            age: row["age"] as? Int ?? 0,
            city: row["city"] as? String ?? "",
            occupation: occupation?.isEmpty == false ? occupation : nil,
            photoPath: (row["photoPath"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isOnline: row["isOnline"] as? Bool ?? false,
            wantsToTalk: row["wantsToTalk"] as? Bool ?? false,
            isVerified: row["isVerified"] as? Bool ?? false,
            pronoun: CandidatePronoun(genderRawValue: row["gender"] as? String)
        )
    }
}
