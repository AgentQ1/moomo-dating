import Foundation

// MARK: - Mode

/// The two ways a speed call can run. "Real Talk" is voice; "Video Match" and
/// the hero card's "Talk to Him/Her/Them" are video.
enum CallMode: String, Codable, Sendable, CaseIterable {
    case voice
    case video

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
