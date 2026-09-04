import SwiftUI

/// The live speed call: their camera, edge to edge, and as little else as the
/// product can get away with.
///
/// The old screen drew the call as a rounded card on a cream page, with the
/// other person's name, age, job, and city printed over the bottom of it. This
/// one is a video call. The remote track fills the display — no card, no
/// corner radius, no gutter, no shadow — over a dark ground that shows through
/// until the first frame actually renders. What remains on top of it is the
/// one thing a Baybe call has that FaceTime does not (that it is three minutes
/// long, and how much of that is left), the safety controls, and mute / end /
/// flip.
///
/// Media comes from the flow's `CallMediaService`: real audio and video over
/// LiveKit in production, or the DEBUG mock — in which case the screen says
/// "Simulated" in as many words. Transport hiccups (connecting, reconnecting)
/// surface over the video without leaving the call.
///
/// Two in-call experiences share this one screen, and neither is allowed to
/// displace the video. Video Match is the plain call: the video, the
/// countdown, and the controls, with nothing arriving over the top of it. Go
/// Play adds a game picker, opened by the pair when they want it — and the
/// date icebreakers are one of the games behind it, so they only ever appear
/// because somebody chose them. In both cases the microphone, the safety menu,
/// minimise, flip, and End Call stay exactly where they were the whole time,
/// and nothing about starting or leaving a game touches media — see
/// `DateIcebreakerSessionModel` and `GoPlaySessionModel`.
struct ActiveCallView: View {
    @ObservedObject var model: CallFlowModel
    var onMinimise: () -> Void

    @State private var isReporting = false
    @State private var isConfirmingBlock = false
    /// True once the remote renderer has actually painted a frame, as reported
    /// by the video view itself. Not "a track exists" — a subscribed track
    /// whose first frame is still in flight would flash an empty rectangle,
    /// and this is what keeps the dark ground up until there is something to
    /// replace it with.
    @State private var isRemoteRendering = false
    /// Where the self-view has been parked, in the video's own coordinates.
    /// Nil until it is first dragged: the tile starts in the top-right corner,
    /// and the corner is computed from the live bounds rather than stored, so
    /// it is still the corner on any screen size.
    @State private var selfPreviewCentre: CGPoint?
    @State private var selfPreviewDrag: CGSize = .zero
    /// The three date prompts. Built once, with the live call's data channel
    /// and the two people on it. `@StateObject` rather than plain state on
    /// purpose: the card is drawn off the session's own published stage, so
    /// this screen has to observe it. A call whose provider has no data
    /// channel gets a session that reports `isAvailable == false`, and no
    /// card ever appears.
    @StateObject private var icebreakers: DateIcebreakerSessionModel
    /// Go Play's lobby, and the only way to the icebreakers. Idle — and
    /// invisible — on a Video Match call.
    @StateObject private var goPlay: GoPlaySessionModel

    private var candidate: DiscoveryCandidate? { model.candidate }

    /// - Parameter localPlayer: who we are, as the in-call experiences see
    ///   us. The call itself never needed the local user's identity; these
    ///   do, and it comes from the tab shell rather than being guessed at
    ///   here.
    init(
        model: CallFlowModel,
        onMinimise: @escaping () -> Void,
        localPlayer: CallGameSeat = CallGameSeat(id: "", displayName: "You")
    ) {
        self.model = model
        self.onMinimise = onMinimise
        // This screen only exists while a call is active, so the session id,
        // the candidate, and the media provider are all settled by now.
        let peer = CallGameSeat(
            id: model.candidate?.id ?? "",
            displayName: model.candidate?.displayName ?? "Them",
            photoPath: model.candidate?.photoPath
        )
        _icebreakers = StateObject(wrappedValue: DateIcebreakerSessionModel(
            transport: model.media.dataTransport,
            sessionID: model.sessionID ?? "",
            localSeat: localPlayer,
            peerSeat: peer
        ))
        _goPlay = StateObject(wrappedValue: GoPlaySessionModel(
            transport: model.media.dataTransport,
            localSeat: localPlayer,
            peerSeat: peer
        ))
    }

    var body: some View {
        ZStack {
            // The ground, under everything and outside every safe area. Dark
            // on purpose: a call whose video has not arrived should look like
            // a call that is starting, not like a blank page.
            Palette.night
                .ignoresSafeArea()

            remoteStage
                .ignoresSafeArea()

            // Legibility only. Clear across the middle two-thirds, which is
            // the face — the wash exists so white chrome survives a bright
            // window behind the person, not to tint them.
            Palette.callScrim
                .ignoresSafeArea()
                .allowsHitTesting(false)

            chrome

            selfPreview

            icebreakerLayer

            goPlayOverlay
        }
        // Materials and system chrome inside the call render as dark glass
        // rather than the app-wide light appearance. The rest of Baybe is a
        // light app; three minutes of full-screen video is not.
        .environment(\.colorScheme, .dark)
        .onAppear {
            icebreakers.begin()
            goPlay.begin()
            // Nothing is scheduled here on purpose. A Video Match call is an
            // ordinary video call — video, clock, and the controls — and the
            // app does not talk over it. The prompts have exactly one door,
            // and it is Go Play's picker (`onChange(of: goPlay.activeGame)`
            // below). With no origin set, the session stays idle and
            // `DateIcebreakerOverlay` draws nothing.
        }
        .onDisappear {
            icebreakers.end()
            goPlay.end()
        }
        // The one clock. Driven from the call's own countdown rather than a
        // timer of this screen's — the countdown is recomputed from the
        // server-set start on both devices, so two phones reach round two
        // together and a suspended one catches up rather than drifting.
        .onChange(of: model.remainingSeconds) { _, _ in
            icebreakers.advance(to: TimeInterval(model.elapsedSeconds))
        }
        .onChange(of: goPlay.activeGame) { _, game in
            guard game == .icebreakers else { return }
            icebreakers.startOnDemand(atElapsed: TimeInterval(model.elapsedSeconds))
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
                // Back to light. The dark override above is for the call
                // surface, which is a video; the report form is a cream page
                // with ink text, and a dark navigation bar over it would put
                // a white title and a white Close button on cream. Reporting
                // someone mid-call is not a place to have an unreadable
                // button.
                .environment(\.colorScheme, .light)
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

    // MARK: - The video

    /// Their camera, full bleed, over the dark fallback.
    ///
    /// The fallback is what the screen is before the first frame lands, while
    /// their camera is off, and in the simulated world. It is deliberately
    /// quiet — the ground plus a dimmed avatar, and no text: this surface has
    /// exactly two lines of writing on it, and neither of them is a name.
    private var remoteStage: some View {
        ZStack {
            if !isRemoteRendering {
                Palette.night

                if let candidate {
                    AvatarView(
                        name: candidate.displayName,
                        photoPath: candidate.photoPath,
                        size: Size.callWaitingAvatar
                    )
                    .opacity(0.5)
                }
            }

            remoteVideo
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Their live camera, when the real provider has a track. Draws nothing
    /// otherwise — the fallback stays visible underneath.
    @ViewBuilder private var remoteVideo: some View {
        #if canImport(LiveKit) && canImport(FirebaseFunctions)
        if let liveKit = model.media as? LiveKitCallMediaService {
            RemoteCallVideoLayer(media: liveKit, isRendering: $isRemoteRendering)
        }
        #endif
    }

    // MARK: - Chrome

    /// Everything drawn over the video that belongs to the call itself. Sits
    /// inside the safe area, so nothing lands under the notch or the home
    /// indicator, while the video underneath it does not.
    private var chrome: some View {
        VStack(spacing: 0) {
            header

            // Inset by the self-view's column: the tile starts parked in
            // this corner, and a "Reconnecting…" that runs under it is a
            // line nobody can read at the moment they most need to.
            mediaStatusLine
                .padding(.top, Space.xs)
                .padding(.trailing, Size.localVideoWidth + Space.sm)

            Spacer(minLength: 0)

            messageSlot

            controls
        }
        .padding(.horizontal, Space.md)
    }

    private var header: some View {
        ZStack {
            VStack(spacing: Space.xxs) {
                Text("3-Minute Speed Call")
                    .font(Typography.callHeader)
                    .foregroundStyle(Palette.textOnDark)

                Text("Time left \(model.formattedRemaining)")
                    .font(Typography.callSubtitle)
                    .foregroundStyle(Palette.textOnDark.opacity(0.85))
                    .accessibilityIdentifier("call.timer")
            }
            .shadow(color: .black.opacity(0.4), radius: 8, y: 1)

            HStack {
                CallGlassButton(icon: "chevron.down", size: Size.callChromeButton) {
                    onMinimise()
                }
                .accessibilityLabel("Minimise call")
                .accessibilityIdentifier("call.minimise")

                Spacer()

                // Report and block, during the call. This is a Guideline 1.2
                // commitment Baybe has made to App Review in writing, not a
                // convenience — it does not get quietly dropped in a visual
                // pass. It is chrome rather than a bottom control so the
                // controls row stays the three a call needs.
                Menu {
                    Button("Report \(candidate?.displayName ?? "user")", systemImage: "flag") {
                        isReporting = true
                    }
                    Button("Block \(candidate?.displayName ?? "user")", systemImage: "hand.raised", role: .destructive) {
                        isConfirmingBlock = true
                    }
                } label: {
                    CallGlassButtonFace(icon: "ellipsis", size: Size.callChromeButton)
                }
                .accessibilityLabel("Call options")
                .accessibilityIdentifier("call.more")
            }
        }
        .frame(height: Size.callHeaderBand)
    }

    /// One honest line about the transport, over the top of the video. Real
    /// media shows nothing while connected; the mock always says it is
    /// simulated.
    @ViewBuilder private var mediaStatusLine: some View {
        if model.media.isSimulated {
            statusText("Simulated call — no audio or video is captured.", color: Palette.textOnDark.opacity(0.8))
        } else {
            switch model.mediaState {
            case .connecting:
                statusText("Connecting audio…", color: Palette.textOnDark.opacity(0.8))
            case .reconnecting:
                statusText("Reconnecting…", color: Palette.coral)
                    .accessibilityIdentifier("call.reconnecting")
            case .failed(let message):
                statusText(message, color: Palette.coral)
            case .idle, .connected, .disconnected:
                EmptyView()
            }
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xxs)
            .background(
                RoundedRectangle(cornerRadius: Radius.pill, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )
    }

    // MARK: - Message slot

    /// A transport failure, or a line from Go Play. The band is reserved
    /// whether or not there is anything to say in it: a message that arrives
    /// mid-call may change what is written above the controls, never where the
    /// controls are.
    private var messageSlot: some View {
        Group {
            if let failure = model.actionFailure {
                messageLine(failure, color: Palette.coral)
            } else if offersGames, let notice = goPlay.notice {
                messageLine(notice, color: Palette.textOnDark.opacity(0.85))
                    .accessibilityIdentifier("callgames.notice")
            }
        }
        .frame(height: Size.callMessageSlot)
        .frame(maxWidth: .infinity)
    }

    private func messageLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
            .transition(.opacity)
    }

    // MARK: - Controls

    /// Mute, End Call, flip — plus Games on a Go Play call, which is the door
    /// to an existing feature rather than a fourth call control. Every one of
    /// them stays on screen and stays live whatever else is drawn over the
    /// video, and every one of them keeps the same size and the same place for
    /// the whole three minutes: a call whose End Call button moves under the
    /// user's thumb is a safety problem, not a layout quirk.
    ///
    /// The circles are flat translucent discs rather than blurred material.
    /// A material behind these would blur a live video frame sixty times a
    /// second for the whole call, which is real latency and real battery for
    /// a texture nobody is looking at.
    private var controls: some View {
        HStack(spacing: Space.lg) {
            CallGlassButton(
                icon: model.isMuted ? "mic.slash.fill" : "mic.fill",
                size: Size.callFloatingControl,
                isProminent: model.isMuted
            ) {
                model.toggleMute()
            }
            .accessibilityLabel(model.isMuted ? "Unmute" : "Mute")
            .accessibilityIdentifier("call.mute")

            // Go Play's door, and only Go Play's: Video Match is a plain
            // video call, not a call with a games menu.
            if offersGames {
                CallGlassButton(
                    icon: "gamecontroller.fill",
                    size: Size.callFloatingControl,
                    isProminent: goPlay.stage == .idle
                ) {
                    if goPlay.activeGame != nil {
                        goPlay.leaveGame()
                    } else if goPlay.stage == .picking {
                        goPlay.closePicker()
                    } else {
                        goPlay.openPicker()
                    }
                }
                .accessibilityLabel(
                    goPlay.activeGame != nil
                        ? "Return to the call"
                        : "Pick a game to play with \(goPlay.peerName)"
                )
                .accessibilityIdentifier("call.games")
            }

            CallGlassButton(
                icon: "phone.down.fill",
                size: Size.callFloatingControl,
                fill: Palette.coral,
                iconColor: .white
            ) {
                model.endCall()
            }
            .accessibilityLabel("End call")
            .accessibilityIdentifier("call.end")

            CallGlassButton(
                icon: "arrow.triangle.2.circlepath.camera.fill",
                size: Size.callFloatingControl
            ) {
                model.flipCamera()
            }
            .accessibilityLabel("Flip camera")
            .accessibilityIdentifier("call.flipCamera")
        }
        .frame(height: Size.callControlsBand)
    }

    // MARK: - Self preview

    /// The corner self-view: small, rounded, draggable, and outside the layout
    /// of everything else.
    ///
    /// It is placed with `position` inside its own reader, so moving it cannot
    /// resize or reflow one pixel of the call — the countdown, the controls,
    /// and any card an in-call experience has up all stay exactly where they
    /// are. Where it may be dragged to is clamped every frame rather than only
    /// on release, so it cannot be flung off the edge, cannot cover the
    /// countdown, and cannot come to rest on top of End Call.
    private var selfPreview: some View {
        GeometryReader { proxy in
            let bounds = proxy.size
            selfPreviewTile
                .frame(width: Size.localVideoWidth, height: Size.localVideoHeight)
                .position(Self.previewCentre(
                    parked: selfPreviewCentre,
                    dragged: selfPreviewDrag,
                    in: bounds
                ))
                .animation(Motion.transition, value: selfPreviewCentre)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { selfPreviewDrag = $0.translation }
                        .onEnded { value in
                            selfPreviewCentre = Self.previewCentre(
                                parked: selfPreviewCentre,
                                dragged: value.translation,
                                in: bounds
                            )
                            selfPreviewDrag = .zero
                        }
                )
        }
    }

    private var selfPreviewTile: some View {
        ZStack {
            Palette.nightRaised

            Image(systemName: model.isCameraOn ? "person.fill" : "video.slash.fill")
                .font(.system(size: 22))
                .foregroundStyle(Palette.textOnDarkSecondary)

            #if canImport(LiveKit) && canImport(FirebaseFunctions)
            if model.isCameraOn, let liveKit = model.media as? LiveKitCallMediaService {
                LocalCallVideoLayer(media: liveKit)
            }
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.localVideo, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.localVideo, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .accessibilityLabel(model.isCameraOn ? "Your camera preview. Drag to move it." : "Your camera is off")
        .accessibilityIdentifier("call.selfPreview")
    }

    /// Where the tile actually sits: its parked centre (or the top-right
    /// corner, when it has never been moved) plus the live drag, clamped into
    /// the region it is allowed to occupy.
    private static func previewCentre(
        parked: CGPoint?,
        dragged: CGSize,
        in bounds: CGSize
    ) -> CGPoint {
        // The far right edge and the very top: "as far into the corner as
        // allowed", which the clamp resolves into the actual corner for
        // whatever screen this is.
        let anchor = parked ?? CGPoint(x: bounds.width, y: 0)
        return clampedPreviewCentre(
            CGPoint(x: anchor.x + dragged.width, y: anchor.y + dragged.height),
            in: bounds
        )
    }

    /// The tile's legal region: inside the screen, below the countdown, above
    /// the controls.
    private static func clampedPreviewCentre(_ point: CGPoint, in bounds: CGSize) -> CGPoint {
        let halfWidth = Size.localVideoWidth / 2
        let halfHeight = Size.localVideoHeight / 2

        let minX = halfWidth + Space.sm
        let maxX = max(minX, bounds.width - halfWidth - Space.sm)
        let minY = halfHeight + Size.callHeaderBand
        let maxY = max(minY, bounds.height - halfHeight - Size.callControlsBand)

        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    // MARK: - In-call experiences

    /// The icebreaker card, held clear of the floating controls so the band
    /// across the bottom of the video never lands on End Call.
    private var icebreakerLayer: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            DateIcebreakerOverlay(session: icebreakers)
        }
        .padding(.bottom, Size.callControlsBand)
    }

    @ViewBuilder private var goPlayOverlay: some View {
        if offersGames, goPlay.isChoosing {
            goPlayLayer
                .padding(Space.md)
                .padding(.bottom, Size.callControlsBand)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
                .animation(Motion.transition, value: goPlay.isChoosing)
        }
    }

    /// Whether this call is the one that offers games at all.
    ///
    /// Both experiences share the one matchmaking pool, so the person on the
    /// other end may well have come in through Go Play while this side chose
    /// Video Match. Their invitation must not open a picker over a screen
    /// whose controls have no Games button — Video Match is a plain call, and
    /// it stays one.
    private var offersGames: Bool {
        model.experience == .goPlay && goPlay.isAvailable
    }

    @ViewBuilder private var goPlayLayer: some View {
        switch goPlay.stage {
        case .picking:
            GoPlayPickerView(session: goPlay)
        case .invitePending, .inviteReceived:
            GoPlayInvitationCard(session: goPlay)
        case .idle, .playing:
            EmptyView()
        }
    }
}

/// A round floating call control: a translucent disc over the video, or a
/// solid one when the control is the loud state (muted, or End Call).
///
/// No blur. See `ActiveCallView.controls` for why a material over a live video
/// frame is the wrong trade on this screen.
private struct CallGlassButton: View {
    var icon: String
    var size: CGFloat
    /// White disc, dark glyph — the FaceTime convention for "this control is
    /// currently doing something to your call".
    var isProminent = false
    var fill: Color?
    var iconColor: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            CallGlassButtonFace(
                icon: icon,
                size: size,
                isProminent: isProminent,
                fill: fill,
                iconColor: iconColor
            )
        }
        .buttonStyle(.plain)
    }
}

/// The disc itself, without a button around it — `Menu` supplies its own.
private struct CallGlassButtonFace: View {
    var icon: String
    var size: CGFloat
    var isProminent = false
    var fill: Color?
    var iconColor: Color?

    private var discColor: Color {
        fill ?? (isProminent ? .white : Color.white.opacity(0.16))
    }

    private var glyphColor: Color {
        iconColor ?? (isProminent ? Palette.ink : .white)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(discColor)
                .overlay(
                    Circle().strokeBorder(
                        Color.white.opacity(fill == nil && !isProminent ? 0.18 : 0),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)

            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(glyphColor)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}
