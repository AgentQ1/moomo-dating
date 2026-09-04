import Foundation

/// One packet off the call's data channel.
struct CallDataPacket: Sendable, Equatable {
    /// The sending participant's identity, as the media provider reports it —
    /// the signed-in uid, minted into the room token by `getCallMediaToken`.
    /// Nil for a packet the provider could not attribute; those are dropped.
    var senderID: String?
    var payload: Data
}

/// A narrow data channel over the call that is already running.
///
/// Deliberately four members wide. The in-call game needs to send bytes, read
/// bytes, know who it is, and know who else is here — and nothing above this
/// protocol is allowed to touch a LiveKit `Room`, because that is how a
/// feature ends up reconnecting or reconfiguring media it does not own. The
/// room belongs to `CallMediaService`; this is a view onto it.
protocol CallDataTransport: AnyObject, Sendable {
    /// Our own participant identity, once the room is connected.
    var localParticipantID: String? { get }

    /// Whether the room will actually carry our data.
    ///
    /// The media provider can hold a perfectly healthy room whose token
    /// forbids data — and a LiveKit client does NOT refuse such a send, it
    /// publishes and the server drops the packet in silence. Without asking
    /// this first, a game invitation looks sent, is never delivered, and the
    /// inviter waits forever on a "Waiting for them to answer…" that can
    /// never end. Anything offering a game must check this.
    var canSendData: Bool { get }

    /// Everyone else in the room right now.
    var remoteParticipantIDs: [String] { get }

    /// Remote participant identities, opening with the current list and
    /// yielding on every join and leave. This is how the game notices the
    /// other player walking away.
    var participantsStream: AsyncStream<[String]> { get }

    /// Inbound packets, from the moment of subscription. Nothing is replayed:
    /// a packet that arrived before anyone was listening is stale by
    /// definition.
    func packets() -> AsyncStream<CallDataPacket>

    /// Sends bytes to everyone else in the room.
    ///
    /// `reliable` is the delivery guarantee, not a priority: lifecycle
    /// messages that strand a player if lost go reliable; per-frame updates
    /// that are superseded milliseconds later go lossy, where a dropped
    /// packet costs nothing and head-of-line blocking would cost lag.
    func send(_ payload: Data, reliable: Bool) async throws
}

/// The default for a provider with no data channel — the honest dead-end
/// provider, and any future provider that carries media only. The game simply
/// doesn't offer itself there.
extension CallMediaService {
    var dataTransport: CallDataTransport? { nil }
}

enum CallDataTransportError: LocalizedError, Equatable {
    /// Asked to send with no live room — the call ended underneath us.
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: "The game lost its connection to the call."
        }
    }
}

#if DEBUG
/// An in-memory transport pair, for tests and the DEBUG mock world.
///
/// `LoopbackDataTransport.pair()` hands back two transports wired into each
/// other, so a test can drive a real two-device conversation — host and
/// guest, invite and accept, snapshots and inputs — with no room, no network,
/// and no timing flake.
final class LoopbackDataTransport: CallDataTransport, @unchecked Sendable {

    let localParticipantID: String?
    /// In-memory delivery is never refused. Tests that want the refusal set
    /// this false.
    var canSendData = true

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<CallDataPacket>.Continuation] = [:]
    private let participants: StreamBroadcaster<[String]>
    /// Where sent bytes go. Weak so a wired pair does not retain itself —
    /// each half is owned by whoever asked for the pair.
    private weak var peer: LoopbackDataTransport?
    /// Simulates a dropped link: sends are swallowed and nothing arrives.
    private var isSevered = false
    /// Everything this transport was asked to send, for assertions.
    private(set) var sent: [(payload: Data, reliable: Bool)] = []
    /// How many times anyone has subscribed for packets, ever. A feature that
    /// tears its listener down and builds a new one on every state change is
    /// a feature that will eventually do the same to the room.
    private(set) var subscriptionCount = 0

    init(localParticipantID: String, remoteParticipantIDs: [String] = []) {
        self.localParticipantID = localParticipantID
        participants = StreamBroadcaster<[String]>(remoteParticipantIDs)
    }

    /// Two transports that can talk to each other.
    static func pair(
        _ firstID: String,
        _ secondID: String
    ) -> (first: LoopbackDataTransport, second: LoopbackDataTransport) {
        let first = LoopbackDataTransport(localParticipantID: firstID, remoteParticipantIDs: [secondID])
        let second = LoopbackDataTransport(localParticipantID: secondID, remoteParticipantIDs: [firstID])
        first.peer = second
        second.peer = first
        return (first, second)
    }

    var remoteParticipantIDs: [String] { participants.value }

    var participantsStream: AsyncStream<[String]> { participants.stream() }

    func packets() -> AsyncStream<CallDataPacket> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                continuations[id] = continuation
                subscriptionCount += 1
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func send(_ payload: Data, reliable: Bool) async throws {
        let (peer, severed) = lock.withLock {
            sent.append((payload, reliable))
            return (self.peer, isSevered)
        }
        guard !severed else { return }
        guard let peer else { throw CallDataTransportError.notConnected }
        peer.deliver(CallDataPacket(senderID: localParticipantID, payload: payload))
    }

    func deliver(_ packet: CallDataPacket) {
        let targets = lock.withLock { Array(continuations.values) }
        targets.forEach { $0.yield(packet) }
    }

    // MARK: Test hooks

    /// Delivers a raw payload to the far side as if this transport had sent
    /// it — for replaying a captured packet (a duplicate, a stale one) or
    /// forging one the real model would never send.
    func deliverToPeerForTesting(_ payload: Data) {
        peer?.deliver(CallDataPacket(senderID: localParticipantID, payload: payload))
    }

    /// The other person left the room.
    func simulatePeerLeft() {
        lock.withLock { isSevered = true }
        participants.send([])
    }

    /// The other person came back.
    func simulatePeerRejoined() {
        guard let peerID = peer?.localParticipantID else { return }
        lock.withLock { isSevered = false }
        participants.send([peerID])
    }

    /// The next send throws, as a send into a dead room does.
    func simulateSendFailure() {
        lock.withLock { peer = nil }
    }

    /// The link drops but nobody leaves the room — a reconnect in progress.
    func simulateLinkDropped() {
        lock.withLock { isSevered = true }
    }

    func simulateLinkRestored() {
        lock.withLock { isSevered = false }
    }
}
#endif
