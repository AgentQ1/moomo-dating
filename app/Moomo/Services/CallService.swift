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

    var errorDescription: String? {
        switch self {
        case .noOneAvailable:
            "No one's free to talk right now. Try again in a bit."
        case .sessionNotReady:
            "The call couldn't be set up. Please try again."
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
