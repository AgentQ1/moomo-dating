import Foundation

// MARK: - Mode

/// How a speed call runs.
///
/// `video` is the only mode the product offers: "Video Match", "Go Play", and
/// the hero card's "Nearby" all start one, and every video call carries the
/// microphone as well as the camera.
///
/// `voice` is the retired voice-only product ("Speed Talk"). It is kept as a
/// **decode-only** case: `users/{uid}/callHistory` and old `callSessions`
/// documents in production still say `"voice"`, and dropping the case would
/// turn those into decode failures or a lying mode label on the Calls tab.
/// Nothing may ever *start* one — `isSupported` is the gate, and the backend
/// refuses a voice queue join, ring, or accept independently.
enum CallMode: String, Codable, Sendable, CaseIterable {
    case voice
    case video

    /// False for modes that exist only to read old records. The one place a
    /// mode may enter a live flow (start, ring, accept) must check this.
    var isSupported: Bool { self == .video }

    /// The mode every new call runs in.
    static let current: CallMode = .video

    var label: String {
        switch self {
        case .voice: "Voice chat"
        case .video: "Video chat"
        }
    }

    var icon: String {
        switch self {
        case .voice: "phone.fill"
        case .video: "video.fill"
        }
    }
}

// MARK: - Ring invites

/// An incoming "someone wants to talk" ring, decoded from our own
/// `callInvites/{uid}` document (`CallInviteLogic`). Exists only while the
/// server says `ringing` — terminal invites never decode, so holding one is
/// proof there is a live ring to answer.
struct CallInvite: Identifiable, Equatable, Sendable {
    /// The caller's uid. The document holds at most one live ring, and the
    /// accept callable addresses it implicitly (our own uid is the doc id),
    /// so the caller is the only identity the invite needs.
    let id: String
    /// Who is ringing us — the participant summary the backend snapshotted
    /// at fan-out time, shaped exactly like a `callSessions` participant.
    let caller: DiscoveryCandidate
    let mode: CallMode
    /// The server's acceptance deadline (`createdAt + RING_TTL_MS`). Accepts
    /// after this lose honestly with `.inviteUnavailable`.
    let expiresAt: Date

    /// How long the banner stays up before auto-dismissing. Deliberately
    /// under the backend's 10s acceptance window (`RING_TTL_MS`) — the same
    /// client-under-server pattern as `FirestoreCallService.searchTimeout`
    /// (30s) vs `QUEUE_ENTRY_TTL_MS` (40s): the UI must give up before the
    /// server would refuse the accept, never after.
    static let ringSeconds: TimeInterval = 7
}

// MARK: - Session

/// A call in progress. Exists only between "connected" and "ended" — the
/// searching and deciding phases have no session, on purpose: holding one is
/// proof there is a live call to return to.
struct CallSession: Identifiable, Equatable, Sendable {
    let id: String
    /// The other person. The local user's identity lives in `SessionStore`.
    let candidate: DiscoveryCandidate
    let mode: CallMode
    let startedAt: Date
    /// The speed-dating clock. The call ends when it runs out.
    let maxDuration: TimeInterval

    /// The product's 3-minute speed call.
    static let speedCallDuration: TimeInterval = 180
}

// MARK: - Decisions

/// The after-call choice each side makes.
enum UserDecision: String, Codable, Sendable {
    case like
    case pass
}

/// What came of the local user's decision.
enum DecisionOutcome: Equatable, Sendable {
    /// You passed. Nothing is created and the other person is never told.
    case passed
    /// You liked them; it wasn't mutual. (The mock resolves the peer's
    /// decision immediately; the real backend resolves it when they decide.)
    case likeSent
    /// Mutual like — a match and its conversation now exist.
    case matched(Match)
}

// MARK: - History

enum CallEndReason: String, Codable, Sendable {
    /// Someone tapped End Call.
    case ended
    /// The 3-minute clock ran out.
    case timeExpired
    /// Ended by blocking the other person.
    case blocked

    var label: String {
        switch self {
        case .ended: "Call ended"
        case .timeExpired: "Time's up"
        case .blocked: "Blocked"
        }
    }
}

/// How a finished call is remembered on the Calls tab.
enum CallOutcome: String, Codable, Sendable {
    /// Call over, decision not made yet.
    case undecided
    case liked
    case passed
    case matched
    case blocked
}

/// One entry in call history.
struct CallRecord: Identifiable, Equatable, Sendable {
    var id: String
    var candidate: DiscoveryCandidate
    var mode: CallMode
    var startedAt: Date
    var duration: TimeInterval
    var endReason: CallEndReason
    var outcome: CallOutcome
}

/// What the decision screen needs once the call itself is gone.
struct CallSummary: Equatable, Sendable {
    var candidate: DiscoveryCandidate
    var mode: CallMode
    var duration: TimeInterval
    var endReason: CallEndReason
    /// The history record this call wrote, so the decision can be stamped
    /// onto it afterwards.
    var recordID: String
}
