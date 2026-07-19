import Foundation

#if canImport(LiveKit) && canImport(FirebaseFunctions)
import FirebaseFunctions
import LiveKit

/// Real call media over LiveKit.
///
/// The client holds no LiveKit credentials: `join` asks the backend's
/// `getCallMediaToken` callable for a token scoped to exactly this session's
/// room (the room name IS the session id), connects, and publishes the
/// microphone — plus the camera for video calls. LiveKit handles transport
/// recovery; its reconnecting/connected transitions surface on `stateStream`
/// so the call screen can say so.
///
/// `ObservableObject` (not just the protocol) because the call screen renders
/// the local/remote video tracks, which only this provider has.
final class LiveKitCallMediaService: NSObject, ObservableObject, CallMediaService, @unchecked Sendable {

    let isSimulated = false

    private let broadcaster = StreamBroadcaster<CallMediaState>(.idle)
    private let presenceBroadcaster = StreamBroadcaster<Bool>(false)
    private let lock = NSLock()
    private var room: Room?

    /// Video tracks for the call screen. Main-actor because SwiftUI reads them.
    @MainActor @Published private(set) var remoteVideoTrack: VideoTrack?
    @MainActor @Published private(set) var localVideoTrack: VideoTrack?

    var stateStream: AsyncStream<CallMediaState> { broadcaster.stream() }

    var remotePresenceStream: AsyncStream<Bool> { presenceBroadcaster.stream() }

    func join(session: CallSession) async throws {
        broadcaster.send(.connecting)

        let response: [String: Any]
        do {
            response = try await FunctionsClient.call(.getCallMediaToken, ["sessionId": session.id])
        } catch {
            let mapped = Self.tokenError(from: error)
            broadcaster.send(.failed(mapped.errorDescription ?? ""))
            throw mapped
        }
        guard
            let url = response["url"] as? String,
            let token = response["token"] as? String
        else {
            broadcaster.send(.failed(CallMediaError.notConfigured.errorDescription ?? ""))
            throw CallMediaError.notConfigured
        }

        let room = Room(delegate: self)
        lock.withLock { self.room = room }

        do {
            try await room.connect(url: url, token: token)
            try await room.localParticipant.setMicrophone(enabled: true)
            if session.mode == .video {
                try await room.localParticipant.setCamera(enabled: true)
            }
        } catch {
            broadcaster.send(.failed(CallMediaError.connectFailed.errorDescription ?? ""))
            await room.disconnect()
            lock.withLock { self.room = nil }
            throw CallMediaError.connectFailed
        }

        broadcaster.send(.connected)
        // The peer may have beaten us into the room; later arrivals and
        // departures come through the delegate.
        presenceBroadcaster.send(!room.remoteParticipants.isEmpty)
    }

    func leave() async {
        let room = lock.withLock {
            let value = self.room
            self.room = nil
            return value
        }
        guard let room else { return }

        await room.disconnect()
        await MainActor.run {
            remoteVideoTrack = nil
            localVideoTrack = nil
        }
        broadcaster.send(.disconnected)
        presenceBroadcaster.send(false)
    }

    func setMuted(_ muted: Bool) async throws {
        guard let room = currentRoom else { return }
        try await room.localParticipant.setMicrophone(enabled: !muted)
    }

    func setCameraEnabled(_ enabled: Bool) async throws {
        guard let room = currentRoom else { return }
        try await room.localParticipant.setCamera(enabled: enabled)
    }

    private var currentRoom: Room? {
        lock.lock(); defer { lock.unlock() }
        return room
    }

    /// "This call has ended" is a fact about the session, not a media
    /// configuration problem — the two must not share copy. The backend marks
    /// it in the error's details payload; everything else from the token
    /// callable stays `notConfigured` (missing provider, malformed response).
    private static func tokenError(from error: Error) -> CallMediaError {
        let details = (error as NSError).userInfo[FunctionsErrorDetailsKey] as? [String: Any]
        return details?["reason"] as? String == "call-ended" ? .sessionEnded : .notConfigured
    }

    /// True while `room` is the live room — stale delegate callbacks from a
    /// room we already left must not resurrect state.
    private func isCurrent(_ room: Room) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.room === room
    }
}

// MARK: - RoomDelegate

extension LiveKitCallMediaService: RoomDelegate {

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        guard isCurrent(room) else { return }
        switch connectionState {
        case .reconnecting:
            broadcaster.send(.reconnecting)
        case .connected:
            // Initial connect is reported by `join` (after publish succeeds);
            // this catches recovery from `reconnecting`.
            if oldConnectionState == .reconnecting {
                broadcaster.send(.connected)
            }
        case .disconnected:
            broadcaster.send(.disconnected)
        case .connecting, .disconnecting:
            break
        }
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        guard isCurrent(room) else { return }
        broadcaster.send(.disconnected)
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        guard isCurrent(room) else { return }
        presenceBroadcaster.send(true)
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard isCurrent(room) else { return }
        presenceBroadcaster.send(!room.remoteParticipants.isEmpty)
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard isCurrent(room), let track = publication.track as? VideoTrack else { return }
        Task { @MainActor in self.remoteVideoTrack = track }
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard isCurrent(room), publication.track is VideoTrack else { return }
        Task { @MainActor in self.remoteVideoTrack = nil }
    }

    func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard isCurrent(room), let track = publication.track as? VideoTrack else { return }
        Task { @MainActor in self.localVideoTrack = track }
    }

    func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        guard isCurrent(room), publication.track is VideoTrack else { return }
        Task { @MainActor in self.localVideoTrack = nil }
    }
}
#endif
