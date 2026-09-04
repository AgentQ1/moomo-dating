import Foundation

#if canImport(LiveKit) && canImport(FirebaseFunctions)
import LiveKit

/// The in-call data channel, over the LiveKit room the call is already using.
///
/// This type exists so that nothing above `CallMediaService` ever holds a
/// `Room`. Everything drawn over a call — the icebreaker cards, Go Play's
/// picker, whatever game comes next — must be invisible to media: no
/// reconnect, no republish, no renegotiation. It is bytes down a channel the
/// room already has, and the video and microphone carry on untouched. Handing
/// the `Room` itself to a feature would make that guarantee a matter of
/// discipline rather than of structure.
///
/// The room is attached and detached by `LiveKitCallMediaService`, which owns
/// its lifetime; this holds it weakly and answers `notConnected` in between.
/// Inbound packets arrive on the media service's `RoomDelegate` and are
/// forwarded here, filtered to our own topic.
final class LiveKitGameTransport: CallDataTransport, @unchecked Sendable {

    private let lock = NSLock()
    private weak var room: Room?
    private var continuations: [UUID: AsyncStream<CallDataPacket>.Continuation] = [:]
    private let participants = StreamBroadcaster<[String]>([])

    var localParticipantID: String? {
        lock.withLock { room }?.localParticipant.identity?.stringValue
    }

    /// Read from the room token's grant, which the server sends back with the
    /// join response. False means `getCallMediaToken` minted a token without
    /// `canPublishData` — usually a backend that has not been deployed with
    /// the grant yet. Publishing anyway would not fail; it would be dropped
    /// server-side, which is far worse than not offering the feature at all.
    var canSendData: Bool {
        lock.withLock { room }?.localParticipant.permissions.canPublishData ?? false
    }

    var remoteParticipantIDs: [String] { participants.value }

    var participantsStream: AsyncStream<[String]> { participants.stream() }

    func packets() -> AsyncStream<CallDataPacket> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.continuations.removeValue(forKey: id) }
            }
        }
    }

    func send(_ payload: Data, reliable: Bool) async throws {
        guard let room = lock.withLock({ self.room }) else {
            throw CallDataTransportError.notConnected
        }
        try await room.localParticipant.publish(
            data: payload,
            options: DataPublishOptions(topic: CallGameWire.topic, reliable: reliable)
        )
    }

    // MARK: - Wiring (media service only)

    /// The call's room is up. Called from `join`, after connect.
    func attach(to room: Room) {
        lock.withLock { self.room = room }
        publishParticipants(of: room)
    }

    /// The call's room is gone. Any send after this fails honestly rather
    /// than silently addressing a dead room.
    func detach() {
        lock.withLock { self.room = nil }
        participants.send([])
    }

    /// Someone joined or left.
    func publishParticipants(of room: Room) {
        participants.send(room.remoteParticipants.keys.map(\.stringValue).sorted())
    }

    /// A packet arrived. Anything on another topic belongs to someone else's
    /// feature (or nobody's) and is dropped without being decoded.
    func deliver(_ data: Data, from identity: String?, topic: String) {
        guard topic == CallGameWire.topic else { return }
        let targets = lock.withLock { Array(continuations.values) }
        targets.forEach { $0.yield(CallDataPacket(senderID: identity, payload: data)) }
    }
}
#endif
