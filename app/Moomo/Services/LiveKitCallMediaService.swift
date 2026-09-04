import AVFoundation
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

    /// Exposure and white balance on whichever camera is live. Owned here
    /// because this is the only object that knows a capture device exists —
    /// see `CameraQualityTuner` for why it touches metering and nothing else.
    private let cameraTuner = CameraQualityTuner()

    // MARK: - Media options

    /// Voice processing on. On a real device these flags are reported to the
    /// server as track features and Apple's VPIO does the actual cancelling;
    /// on the simulator they select WebRTC's software APM. Stated either way
    /// so the two behave the same from here.
    private static let audioCaptureOptions = AudioCaptureOptions(
        echoCancellation: true,
        autoGainControl: true,
        noiseSuppression: true
    )

    /// Front camera, 1080p 16:9, 30fps.
    ///
    /// These are targets, not demands: the capturer picks the closest
    /// supported format by aspect ratio first, then frame rate, then distance
    /// from the requested size — so a phone whose front camera has no 1080p30
    /// 16:9 format lands on the nearest one it does have rather than failing.
    ///
    /// 30 and not 60. 60fps would double the encode and radio cost of a
    /// three-minute handheld call for a difference nobody looks at a face and
    /// notices, and there is no measured device/thermal/network gate here to
    /// decide when it would be safe.
    private static let cameraCaptureOptions = CameraCaptureOptions(
        position: .front,
        dimensions: .h1080_169,
        fps: 30
    )

    /// What goes on the wire. Simulcast on, so the far side can drop to a
    /// smaller layer instead of freezing, with 360p and 720p rungs under the
    /// 1080p top one.
    ///
    /// The ceiling is deliberately under LiveKit's own 1080p preset
    /// (3.0 Mbps): a dating call is two faces, mostly still, and the last
    /// half-megabit of headroom buys sharper hair rather than a call that
    /// holds together on a train. `maintainFramerate` is the same trade said
    /// again — when bandwidth drops, lose pixels, not motion. A face at 30fps
    /// and 540p reads as a person; a face at 1080p and 8fps reads as a
    /// slideshow.
    private static let videoPublishOptions = VideoPublishOptions(
        encoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 30),
        simulcast: true,
        simulcastLayers: [.presetH360_169, .presetH720_169],
        degradationPreference: .maintainFramerate
    )

    /// Adaptive stream and dynacast: the subscriber's renderer size drives the
    /// layer it receives, and layers nobody is watching stop being encoded.
    /// Both matter on this screen, where the self-view is a thumbnail and the
    /// remote is full-bleed.
    private static let roomOptions = RoomOptions(
        defaultCameraCaptureOptions: cameraCaptureOptions,
        defaultAudioCaptureOptions: audioCaptureOptions,
        defaultVideoPublishOptions: videoPublishOptions,
        adaptiveStream: true,
        dynacast: true
    )

    /// The in-call game's data channel. Created once and attached to whatever
    /// room is live: the game never learns the room exists, so entering or
    /// leaving a game cannot disturb the audio and video on it.
    private let gameTransport = LiveKitGameTransport()

    var dataTransport: CallDataTransport? { gameTransport }

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

        let room = Room(delegate: self, roomOptions: Self.roomOptions)
        lock.withLock { self.room = room }

        do {
            try await room.connect(url: url, token: token)
            try await room.localParticipant.setMicrophone(
                enabled: true,
                captureOptions: Self.audioCaptureOptions
            )
            if session.mode == .video {
                try await room.localParticipant.setCamera(
                    enabled: true,
                    captureOptions: Self.cameraCaptureOptions,
                    publishOptions: Self.videoPublishOptions
                )
                await tuneLiveCamera(in: room)
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
        gameTransport.attach(to: room)
    }

    func leave() async {
        let room = lock.withLock {
            let value = self.room
            self.room = nil
            return value
        }
        guard let room else { return }

        gameTransport.detach()
        cameraTuner.detach()
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
        try await room.localParticipant.setCamera(
            enabled: enabled,
            captureOptions: Self.cameraCaptureOptions,
            publishOptions: Self.videoPublishOptions
        )
        if enabled {
            await tuneLiveCamera(in: room)
        } else {
            cameraTuner.detach()
        }
    }

    /// Front to back and back again, on the capturer LiveKit already owns.
    ///
    /// `switchCameraPosition` restarts capture on the other device and leaves
    /// the publication — and therefore the room, the encoder, and the far
    /// side's subscription — untouched. Nothing about the call is renegotiated.
    /// The tuning is re-applied afterwards because it belongs to the device,
    /// and the device just changed.
    ///
    /// No camera publication (a voice call, or the camera switched off) is not
    /// an error: there is nothing to flip, and inventing a failure message for
    /// it would be a lie.
    func flipCamera() async throws {
        guard let room = currentRoom, let capturer = Self.cameraCapturer(in: room) else { return }
        try await capturer.switchCameraPosition()
        cameraTuner.attach(to: capturer.device)
    }

    /// The live camera capturer, when there is one.
    private static func cameraCapturer(in room: Room) -> CameraCapturer? {
        guard
            let publication = room.localParticipant.firstCameraPublication,
            let track = publication.track as? LocalVideoTrack
        else { return nil }
        return track.capturer as? CameraCapturer
    }

    /// Points the tuner at whichever device the capturer resolved.
    ///
    /// `startCapture` sets the device as its last act, and publishing awaits
    /// it, so one look is normally enough — the retry covers the case where
    /// the publication lands a beat before the capture session settles. A
    /// device that never appears means no tuning, not a failed call.
    private func tuneLiveCamera(in room: Room) async {
        for attempt in 0 ..< 3 {
            if let device = Self.cameraCapturer(in: room)?.device {
                cameraTuner.attach(to: device)
                return
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(150)) }
        }
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
        gameTransport.publishParticipants(of: room)
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard isCurrent(room) else { return }
        presenceBroadcaster.send(!room.remoteParticipants.isEmpty)
        gameTransport.publishParticipants(of: room)
    }

    /// In-call game packets. Filtered by topic inside the transport — this
    /// channel carries the game and nothing else, and a packet on any other
    /// topic is dropped without being decoded.
    func room(
        _ room: Room,
        participant: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic topic: String,
        encryptionType: EncryptionType
    ) {
        guard isCurrent(room) else { return }
        gameTransport.deliver(data, from: participant?.identity?.stringValue, topic: topic)
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
