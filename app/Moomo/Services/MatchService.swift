import Foundation

/// Decisions and matches.
///
/// The invariant this service owns: a `Match` exists if and only if both
/// people liked each other. Nothing else may create one.
protocol MatchService: Sendable {
    /// Current matches, newest first. Opens with the current list.
    var matchesStream: AsyncStream<[Match]> { get }

    func matches() async -> [Match]

    /// Records the local decision about someone and resolves the outcome.
    /// The mock resolves the peer's decision immediately; the real backend
    /// resolves it whenever they decide.
    ///
    /// `callSessionID` ties the decision to the call it came from — the
    /// backend verifies the caller was a participant of that session, which
    /// is what stops "liking" people you never talked to. The mock ignores it.
    func submitDecision(
        _ decision: UserDecision,
        about candidate: DiscoveryCandidate,
        callSessionID: String?
    ) async throws -> DecisionOutcome
}

extension MatchService {
    /// Convenience for callers (and tests) without a call session at hand.
    func submitDecision(
        _ decision: UserDecision,
        about candidate: DiscoveryCandidate
    ) async throws -> DecisionOutcome {
        try await submitDecision(decision, about: candidate, callSessionID: nil)
    }
}

/// In-memory matches with a simulated peer.
///
/// The peer's decision is deterministic, not random: someone flagged as
/// "wants to talk to you" always likes back, everyone else by a stable hash
/// of their id (~half). Deterministic means tests and demos behave the same
/// on every run.
final class MockMatchService: MatchService, @unchecked Sendable {

    private let latency: Duration
    private let peerDecision: @Sendable (DiscoveryCandidate) -> UserDecision
    /// Runs on every mutual like — wired by `AppServices` to create the
    /// conversation and the match notification, the way a backend job would.
    private let onMatch: @Sendable (Match) async -> Void

    private let broadcaster = StreamBroadcaster<[Match]>([])

    init(
        latency: Duration = .milliseconds(500),
        peerDecision: @escaping @Sendable (DiscoveryCandidate) -> UserDecision = {
            MockMatchService.defaultPeerDecision(for: $0)
        },
        onMatch: @escaping @Sendable (Match) async -> Void = { _ in }
    ) {
        self.latency = latency
        self.peerDecision = peerDecision
        self.onMatch = onMatch
    }

    var matchesStream: AsyncStream<[Match]> { broadcaster.stream() }

    func matches() async -> [Match] { broadcaster.value }

    func submitDecision(
        _ decision: UserDecision,
        about candidate: DiscoveryCandidate,
        callSessionID: String?
    ) async throws -> DecisionOutcome {
        try await Task.sleep(for: latency)

        guard decision == .like else { return .passed }
        guard peerDecision(candidate) == .like else { return .likeSent }

        // Already matched with them (a repeat call): don't mint a duplicate.
        if let existing = broadcaster.value.first(where: { $0.candidate.id == candidate.id }) {
            return .matched(existing)
        }

        let match = Match(
            id: UUID().uuidString,
            candidate: candidate,
            createdAt: Date(),
            conversationID: UUID().uuidString
        )
        broadcaster.update { $0.insert(match, at: 0) }
        await onMatch(match)
        return .matched(match)
    }

    /// Mock-graph wiring for the block cascade the backend runs server-side.
    func removeMatches(with userID: String) async {
        broadcaster.update { $0.removeAll { $0.candidate.id == userID } }
    }

    // MARK: - Peer simulation

    static func defaultPeerDecision(for candidate: DiscoveryCandidate) -> UserDecision {
        if candidate.wantsToTalk { return .like }
        return stableHash(candidate.id) % 2 == 0 ? .like : .pass
    }

    /// FNV-1a, deterministic across launches — same rationale as
    /// `AvatarView`'s colour hash. Swift's `hashValue` is seeded per process.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
