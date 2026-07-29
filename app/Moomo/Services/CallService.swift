import Foundation

/// Matchmaking and call history.
///
/// A protocol so the real matchmaking backend (Firestore `callSessions` +
/// WebRTC) drops in without touching the call flow. The mock runs the same
/// state sequence with simulated latency and no media.
protocol CallService: Sendable {
    /// Finds someone to talk to in `mode`. `preferred` is the "Talk to Him"
    /// case — the featured person is asked first. Cancellation aborts the
    /// search cleanly.
    func findCandidate(mode: CallMode, preferring preferred: DiscoveryCandidate?) async throws -> DiscoveryCandidate

    /// Establishes the call with a found candidate.
    func connect(to candidate: DiscoveryCandidate, mode: CallMode) async throws -> CallSession

    /// The foreground incoming-ring feed: yields the currently ringing
    /// invite, or nil when there is none (never rung, withdrawn, expired,
    /// or already answered). Nil matters — it takes the banner down.
    func incomingInvites() -> AsyncStream<CallInvite?>

    /// Answers a ring. First accepter wins server-side; success returns the
    /// caller as the candidate for the immediately-following
    /// `connect(to:mode:)` — the session already exists by then, exactly
    /// like an instant match. Losing the race, an expired ring, a caller
    /// who left, or a block between the pair (all indistinguishable by
    /// design) throw `CallServiceError.inviteUnavailable`.
    func acceptInvite(_ invite: CallInvite) async throws -> DiscoveryCandidate

    /// Says no to a ring. Best-effort cleanup like leaving the queue:
    /// errors are swallowed, because the invite expires server-side anyway.
    func declineInvite(_ invite: CallInvite) async

    /// Emits when the server ends the session out from under us — the peer
    /// hung up (or blocked; the two are indistinguishable by design). Never
    /// emits for our own `record()`. Finishes after the first event.
    func endEvents(for sessionID: String) -> AsyncStream<CallEndReason>

    /// Finished calls, newest first. Opens with the current history.
    var historyStream: AsyncStream<[CallRecord]> { get }

    func history() async -> [CallRecord]

    /// Appends a finished call to history.
    func record(_ record: CallRecord) async

    /// Stamps the after-call decision onto an existing record.
    func setOutcome(_ outcome: CallOutcome, forRecord id: String) async
}

enum CallServiceError: LocalizedError, Equatable {
    case noOneAvailable
    /// `connect` was asked for a session that `findCandidate` never produced
    /// (or produced for someone else). A client-sequencing bug, surfaced
    /// honestly rather than fabricating a call.
    case sessionNotReady
    /// An accepted ring the server couldn't honour: someone else answered
    /// first, the ring expired, the caller gave up — or a block sits between
    /// the pair, which must read exactly the same (silent-block invariant).
    case inviteUnavailable

    var errorDescription: String? {
        switch self {
        case .noOneAvailable:
            "No one's free to talk right now. Try again in a bit."
        case .sessionNotReady:
            "The call couldn't be set up. Please try again."
        case .inviteUnavailable:
            "Looks like they just connected with someone else."
        }
    }
}

/// In-memory matchmaking with realistic latency, so the searching and
/// connecting states are exercised for real. No audio or video is ever
/// captured — the call screen says so.
final class MockCallService: CallService, @unchecked Sendable {

    private let searchLatency: Duration
    private let connectLatency: Duration
    /// Who matchmaking can produce. Defaults to the same people Discover shows.
    private let pool: [DiscoveryCandidate]
    /// Wired to the safety service so a blocked person can never be matched,
    /// even as the "preferred" candidate.
    private let isBlocked: @Sendable (String) async -> Bool

    private let historyBroadcaster = StreamBroadcaster<[CallRecord]>([])

    /// The current ring, nil when silent — the same "latest value + changes"
    /// shape the Firestore listener exposes.
    private let inviteBroadcaster = StreamBroadcaster<CallInvite?>(nil)

    private let declinedLock = NSLock()
    private var recordedDeclines: [CallInvite] = []

    private let endEventsLock = NSLock()
    private var endEventContinuations: [String: [AsyncStream<CallEndReason>.Continuation]] = [:]

    init(
        searchLatency: Duration = .milliseconds(1400),
        connectLatency: Duration = .milliseconds(900),
        pool: [DiscoveryCandidate] = DiscoveryState.sample.allCandidates,
        isBlocked: @escaping @Sendable (String) async -> Bool = { _ in false }
    ) {
        self.searchLatency = searchLatency
        self.connectLatency = connectLatency
        self.pool = pool
        self.isBlocked = isBlocked
    }

    func findCandidate(
        mode: CallMode,
        preferring preferred: DiscoveryCandidate?
    ) async throws -> DiscoveryCandidate {
        try await Task.sleep(for: searchLatency)

        if let preferred, await !isBlocked(preferred.id) {
            return preferred
        }

        var available: [DiscoveryCandidate] = []
        for candidate in pool {
            if await !isBlocked(candidate.id) {
                available.append(candidate)
            }
        }
        guard let candidate = available.randomElement() else {
            throw CallServiceError.noOneAvailable
        }
        return candidate
    }

    func connect(to candidate: DiscoveryCandidate, mode: CallMode) async throws -> CallSession {
        try await Task.sleep(for: connectLatency)
        return CallSession(
            id: UUID().uuidString,
            candidate: candidate,
            mode: mode,
            startedAt: Date(),
            maxDuration: CallSession.speedCallDuration
        )
    }

    // MARK: - Ring invites

    func incomingInvites() -> AsyncStream<CallInvite?> {
        inviteBroadcaster.stream()
    }

    /// Accepting consumes the ring — the real backend flips the document to
    /// `accepted`, which the listener reduces to nil — and hands back the
    /// caller for the follow-up `connect`. The block check mirrors the real
    /// callable's transactional safety invariant: a blocked pair answers
    /// "unavailable", never "blocked".
    func acceptInvite(_ invite: CallInvite) async throws -> DiscoveryCandidate {
        if await isBlocked(invite.caller.id) {
            throw CallServiceError.inviteUnavailable
        }
        inviteBroadcaster.send(nil)
        return invite.caller
    }

    /// Declines are recorded for test assertions and the ring is consumed,
    /// matching the real service's write of a terminal `declined` status.
    func declineInvite(_ invite: CallInvite) async {
        declinedLock.lock()
        recordedDeclines.append(invite)
        declinedLock.unlock()
        inviteBroadcaster.send(nil)
    }

    /// The invites `declineInvite` was asked to report, oldest first.
    var declinedInvites: [CallInvite] {
        declinedLock.lock()
        defer { declinedLock.unlock() }
        return recordedDeclines
    }

    #if DEBUG
    /// Test/debug hook: the backend fans a ring out to us. `expiresAt`
    /// defaults to the server's 10s acceptance window (`RING_TTL_MS`).
    @discardableResult
    func simulateIncomingInvite(
        caller: DiscoveryCandidate,
        mode: CallMode,
        expiresAt: Date = Date().addingTimeInterval(10)
    ) -> CallInvite {
        let invite = CallInvite(id: caller.id, caller: caller, mode: mode, expiresAt: expiresAt)
        inviteBroadcaster.send(invite)
        return invite
    }

    /// Test/debug hook: the ring ends without us — cancelled, expired, or
    /// answered by someone faster.
    func simulateInviteWithdrawn() {
        inviteBroadcaster.send(nil)
    }
    #endif

    // MARK: - Peer end

    /// The simulated peer never hangs up on their own; tests drive it via
    /// `simulatePeerEnded`.
    func endEvents(for sessionID: String) -> AsyncStream<CallEndReason> {
        AsyncStream { continuation in
            endEventsLock.lock()
            endEventContinuations[sessionID, default: []].append(continuation)
            endEventsLock.unlock()
        }
    }

    /// Test hook: the pretend peer ends the call.
    func simulatePeerEnded(sessionID: String) {
        endEventsLock.lock()
        let continuations = endEventContinuations.removeValue(forKey: sessionID) ?? []
        endEventsLock.unlock()
        for continuation in continuations {
            continuation.yield(.ended)
            continuation.finish()
        }
    }

    // MARK: - History

    var historyStream: AsyncStream<[CallRecord]> { historyBroadcaster.stream() }

    func history() async -> [CallRecord] { historyBroadcaster.value }

    func record(_ record: CallRecord) async {
        historyBroadcaster.update { $0.insert(record, at: 0) }
    }

    func setOutcome(_ outcome: CallOutcome, forRecord id: String) async {
        historyBroadcaster.update { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].outcome = outcome
        }
    }
}

extension DiscoveryState {
    /// Everyone this state shows, for use as a matchmaking pool.
    var allCandidates: [DiscoveryCandidate] {
        ([featured] + nearby.map(Optional.some)).compactMap { $0 }
    }
}
