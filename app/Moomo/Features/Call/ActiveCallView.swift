import SwiftUI

/// The live speed call, matching the light reference: cream canvas, a header
/// with the countdown under the title, one large rounded video card with a
/// warm halo, the caller's identity overlaid bottom-left, and three labelled
/// controls beneath — with the ghost mascot peeking over End Call.
///
/// Media comes from the flow's `CallMediaService`: real audio/video over
/// LiveKit in production, or the DEBUG mock — in which case the screen says
/// "Simulated" in as many words. Transport hiccups (connecting, reconnecting)
/// surface over the video without leaving the call.
struct ActiveCallView: View {
    @ObservedObject var model: CallFlowModel
    var onMinimise: () -> Void

    @State private var isReporting = false
    @State private var isConfirmingBlock = false

    private var candidate: DiscoveryCandidate? { model.candidate }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Space.xs)
                .padding(.top, Space.xxs)

            videoCard
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.cardGap)

            if let failure = model.actionFailure {
                Text(failure)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.coral)
                    .multilineTextAlignment(.center)
                    .padding(.top, Space.xs)
                    .padding(.horizontal, Space.xl)
            }

            controls
                .padding(.top, Space.md)
                .padding(.bottom, Space.xs)
        }
        .sheet(isPresented: $isReporting) {
            if let candidate {
                ReportUserSheet(
                    candidateName: candidate.displayName,
                    didSubmit: model.didSubmitReport,
                    failure: model.actionFailure,
                    onSubmit: { reason, details in
                        Task { await model.submitReport(reason: reason, details: details) }
                    }
                )
            }
        }
        .confirmationDialog(
            "Block \(candidate?.displayName ?? "this person")?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                Task { await model.blockAndFinish() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ends the call. They disappear from Discover, matches, and chat, and they won't be told.")
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            VStack(spacing: Space.xxs) {
                Text("3-Minute Speed Call")
                    .font(Typography.callHeader)
                    .foregroundStyle(Palette.ink)

                Text("Time left \(model.formattedRemaining)")
                    .font(Typography.callSubtitle)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityIdentifier("call.timer")
            }

            HStack {
                Button(action: onMinimise) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: Size.minTapTarget, height: Size.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Minimise call")
                .accessibilityIdentifier("call.minimise")

                Spacer()

                Menu {
                    Button("Report \(candidate?.displayName ?? "user")", systemImage: "flag") {
                        isReporting = true
                    }
                    Button("Block \(candidate?.displayName ?? "user")", systemImage: "hand.raised", role: .destructive) {
                        isConfirmingBlock = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: Size.minTapTarget, height: Size.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Call options")
                .accessibilityIdentifier("call.more")
            }
        }
    }

    // MARK: - Video card

    private var videoCard: some View {
        ZStack {
            remoteLayer
            Palette.callScrim
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if model.mode == .video {
                localPreview
                    .padding(Space.sm)
            }
        }
        .overlay(alignment: .bottomLeading) {
            identityOverlay
                .padding(.leading, Space.lg)
                .padding(.bottom, Space.xl)
        }
        .overlay(alignment: .top) {
            mediaStatusLine
                .padding(.top, Space.sm)
                .padding(.horizontal, Space.md)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.callCard, style: .continuous))
        .shadow(Shadows.callCard)
    }

    /// Their live camera over the placeholder. The placeholder — dark ground
    /// and avatar — is what the card shows before frames arrive, in voice
    /// mode, and in the simulated world.
    private var remoteLayer: some View {
        ZStack {
            Palette.night

            if let candidate {
                AvatarView(name: candidate.displayName, photoPath: candidate.photoPath, size: Size.heroAvatar * 0.8)
            }

            remoteVideo
        }
    }

    /// Their live camera, when the real provider has a track. Draws nothing
    /// otherwise — the placeholder stays visible underneath.
    @ViewBuilder private var remoteVideo: some View {
        #if canImport(LiveKit) && canImport(FirebaseFunctions)
        if let liveKit = model.media as? LiveKitCallMediaService {
            RemoteCallVideoLayer(media: liveKit)
        }
        #endif
    }

    /// The corner self-view. Shows the real local camera once published; the
    /// placeholder underneath is the camera-off (and mock) state.
    private var localPreview: some View {
        RoundedRectangle(cornerRadius: Radius.localVideo, style: .continuous)
            .fill(Palette.nightRaised)
            .frame(width: Size.localVideoWidth, height: Size.localVideoHeight)
            .overlay {
                ZStack {
                    Image(systemName: model.isCameraOn ? "person.fill" : "video.slash.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.textOnDarkSecondary)

                    #if canImport(LiveKit) && canImport(FirebaseFunctions)
                    if model.isCameraOn, let liveKit = model.media as? LiveKitCallMediaService {
                        LocalCallVideoLayer(media: liveKit)
                    }
                    #endif
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.localVideo, style: .continuous))
            .accessibilityLabel(model.isCameraOn ? "Your camera preview" : "Your camera is off")
    }

    // MARK: - Identity overlay

    @ViewBuilder private var identityOverlay: some View {
        if let candidate {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Text("\(candidate.displayName), \(candidate.age)")
                        .font(Typography.heroTitle)
                        .foregroundStyle(Palette.textOnDark)

                    if candidate.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Palette.verifiedOlive)
                            .accessibilityLabel("Verified")
                    }
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: Space.xxs) {
                    if let occupation = candidate.occupation {
                        detailRow(icon: "graduationcap.fill", text: occupation)
                    }
                    if !candidate.city.isEmpty {
                        detailRow(icon: "mappin.and.ellipse", text: candidate.city)
                    }
                }
            }
        }
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: Space.xs - 2) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Size.iconSmall)
            Text(text)
                .font(Typography.callDetail)
        }
        .foregroundStyle(Palette.textOnDark.opacity(0.92))
    }

    // MARK: - Media status

    /// One honest line about the transport, over the top of the video. Real
    /// media shows nothing while connected; the mock always says it is
    /// simulated.
    @ViewBuilder private var mediaStatusLine: some View {
        if model.media.isSimulated {
            Text("Simulated call — no audio or video is captured.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textOnDark.opacity(0.75))
        } else {
            switch model.mediaState {
            case .connecting:
                Label("Connecting audio…", systemImage: "waveform")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textOnDark.opacity(0.75))
            case .reconnecting:
                Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.coral)
                    .accessibilityIdentifier("call.reconnecting")
            case .failed(let message):
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.coral)
            case .idle, .connected, .disconnected:
                EmptyView()
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(alignment: .top, spacing: Space.xxxl) {
            CallControlButton(
                icon: model.isMuted ? "mic.slash.fill" : "mic.fill",
                label: model.isMuted ? "Unmute" : "Mute",
                isOff: model.isMuted
            ) {
                model.toggleMute()
            }
            .accessibilityIdentifier("call.mute")

            endControl

            if model.mode == .video {
                CallControlButton(
                    icon: model.isCameraOn ? "video.fill" : "video.slash.fill",
                    label: model.isCameraOn ? "Camera" : "Cam off",
                    isOff: !model.isCameraOn
                ) {
                    model.toggleCamera()
                }
                .accessibilityIdentifier("call.camera")
            } else {
                // Keeps End Call centred in voice mode.
                Color.clear
                    .frame(width: Size.callSecondaryControl, height: Size.callEndControl)
                    .accessibilityHidden(true)
            }
        }
    }

    private var endControl: some View {
        Button {
            model.endCall()
        } label: {
            VStack(spacing: Space.xs) {
                ZStack {
                    Circle()
                        .fill(Palette.coral)
                        .frame(width: Size.callEndControl, height: Size.callEndControl)
                        .shadow(Shadows.coralCTA)
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .overlay(alignment: .top) {
                    GhostSticker()
                        .frame(width: 27, height: 30)
                        .offset(x: 25, y: -14)
                        .allowsHitTesting(false)
                }

                Text("End Call")
                    .font(Typography.callControlLabel)
                    .foregroundStyle(Palette.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End call")
        .accessibilityIdentifier("call.end")
    }
}

/// A secondary round call control (mute, camera): white circle, label under.
/// `isOff` is the toggled-away state — dark fill, so the state is legible at
/// a glance.
private struct CallControlButton: View {
    var icon: String
    var label: String
    var isOff: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                ZStack {
                    Circle()
                        .fill(isOff ? Palette.ink : Color.white)
                        .frame(width: Size.callSecondaryControl, height: Size.callSecondaryControl)
                        .shadow(Shadows.card)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(isOff ? Color.white : Palette.ink)
                }
                // The end control's circle is taller; matching its slot keeps
                // all three circles centre-aligned and the labels on one line.
                .frame(height: Size.callEndControl)

                Text(label)
                    .font(Typography.callControlLabel)
                    .foregroundStyle(Palette.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
