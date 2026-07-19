import Foundation

/// The media plane of a call: microphone/camera capture and transport.
///
/// Deliberately separate from `CallService` (matchmaking and session state) so
/// the provider is swappable and the call state machine stays testable without
/// media hardware. The real implementation is `LiveKitCallMediaService`; the
/// mock exists for tests, previews, and the DEBUG no-backend world only, and
/// captures nothing.
protocol CallMediaService: Sendable {
    /// True only for the DEBUG mock. The call screen labels the call
    /// "Simulated" when set — the product never pretends fake media is real.
    var isSimulated: Bool { get }

    /// Connection state, opening with the current value.
    var stateStream: AsyncStream<CallMediaState> { get }

    /// Whether anyone else is in the media room, opening with the current
    /// value. Drives the empty-room bail-out: a "call" nobody ever joined
    /// must not run its full three minutes of silence.
    var remotePresenceStream: AsyncStream<Bool> { get }

    /// Joins the media room for `session`, publishing the microphone (and the
    /// camera for video calls). Returns once media is flowing.
    func join(session: CallSession) async throws

    /// Leaves the room and releases capture devices. Safe to call twice.
    func leave() async

    func setMuted(_ muted: Bool) async throws
    func setCameraEnabled(_ enabled: Bool) async throws
}

enum CallMediaState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    /// Transport dropped; the provider is trying to restore it.
    case reconnecting
    /// Gone for good: we left, were disconnected, or reconnection gave up.
    case disconnected
    case failed(String)
}

enum CallMediaError: LocalizedError, Equatable {
    /// The backend has no media provider configured (or the SDK is missing).
    case notConfigured
    /// The session was already over when we asked to join — the other person
    /// gave up (or their media never came up) before we got in.
    case sessionEnded
    case connectFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Calls aren't available right now. Please try again later."
        case .sessionEnded:
            "That call ended before you could join. Try another search."
        case .connectFailed:
            "We couldn't connect audio and video. Please try again."
        }
    }
}

/// The honest dead-end for builds where a real provider cannot exist (Firebase
/// linked but the LiveKit SDK missing). Joining fails loudly; nothing is
/// simulated. This must never be reachable from a correctly configured build.
struct UnavailableCallMediaService: CallMediaService {
    let isSimulated = false
    var stateStream: AsyncStream<CallMediaState> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    var remotePresenceStream: AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(false)
            continuation.finish()
        }
    }

    func join(session: CallSession) async throws { throw CallMediaError.notConfigured }
    func leave() async {}
    func setMuted(_ muted: Bool) async throws {}
    func setCameraEnabled(_ enabled: Bool) async throws {}
}

#if DEBUG
/// No-media stand-in for tests, previews, and the DEBUG no-backend world.
/// Captures and transmits nothing; the call screen says "Simulated".
final class MockCallMediaService: CallMediaService, @unchecked Sendable {
    let isSimulated = true

    /// Injectable failures so flows under test can exercise every branch.
    private let joinError: CallMediaError?
    private let controlsFail: Bool
    /// Whether the pretend peer shows up in the room after `join`. True by
    /// default so the simulated world behaves like a call that worked; ghost
    /// tests pass false and (optionally) arrive late via `simulatePeerJoined`.
    private let peerJoins: Bool
    private let broadcaster = StreamBroadcaster<CallMediaState>(.idle)
    private let presenceBroadcaster = StreamBroadcaster<Bool>(false)

    init(joinError: CallMediaError? = nil, controlsFail: Bool = false, peerJoins: Bool = true) {
        self.joinError = joinError
        self.controlsFail = controlsFail
        self.peerJoins = peerJoins
    }

    var stateStream: AsyncStream<CallMediaState> { broadcaster.stream() }

    var remotePresenceStream: AsyncStream<Bool> { presenceBroadcaster.stream() }

    func join(session: CallSession) async throws {
        broadcaster.send(.connecting)
        if let joinError {
            broadcaster.send(.failed(joinError.errorDescription ?? "failed"))
            throw joinError
        }
        broadcaster.send(.connected)
        if peerJoins {
            presenceBroadcaster.send(true)
        }
    }

    func leave() async {
        broadcaster.send(.disconnected)
        presenceBroadcaster.send(false)
    }

    func setMuted(_ muted: Bool) async throws {
        if controlsFail { throw CallMediaError.connectFailed }
    }

    func setCameraEnabled(_ enabled: Bool) async throws {
        if controlsFail { throw CallMediaError.connectFailed }
    }

    /// Test hook: the transport dies mid-call (network loss the provider
    /// could not recover from).
    func simulateTransportLost() {
        broadcaster.send(.disconnected)
    }

    /// Test hook: the peer arrives (late) in the room.
    func simulatePeerJoined() {
        presenceBroadcaster.send(true)
    }
}
#endif
