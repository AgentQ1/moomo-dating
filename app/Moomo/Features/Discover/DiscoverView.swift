import SwiftUI

/// Discover home. Matches reference 3.
struct DiscoverView: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject var model: DiscoverModel
    @ObservedObject var coordinator: CallCoordinator

    @State private var isShowingLocationPicker = false
    @State private var isShowingIntentionPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DiscoverLocationBar(
                    title: locationTitle,
                    intention: session.user?.profile.datingIntention,
                    onOpenLocation: { isShowingLocationPicker = true },
                    onOpenIntention: { isShowingIntentionPicker = true }
                )
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.xs)

                if coordinator.hasMinimisedCall {
                    returnToCallBanner
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.md)
                }

                content
                    .padding(.top, Space.md)

                Text("CHAT MODES")
                    .font(Typography.sectionLabel)
                    .tracking(Typography.sectionTracking)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xl)
                    .padding(.bottom, Space.sm)

                chatModes
                    .padding(.horizontal, Space.gutter)

                // Clears the floating tab bar, which overlays the scroll view
                // rather than insetting it.
                Color.clear.frame(height: Size.tabBarHeight + Space.xxl)
            }
        }
        .background(Palette.canvas)
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $isShowingLocationPicker) {
            LocationPickerView(current: session.user?.profile.location) { city in
                Task { await save { $0.location = city } }
            }
        }
        .sheet(isPresented: $isShowingIntentionPicker) {
            DatingIntentionPickerView(current: session.user?.profile.datingIntention) { intention in
                Task { await save { $0.datingIntention = intention } }
            }
        }
    }

    /// "Chicago, IL", or a prompt when the profile carries no city. Every
    /// account that finished onboarding has one — this covers the gap while a
    /// restored session's profile is still loading.
    private var locationTitle: String {
        session.user?.profile.location?.compactDisplay ?? "Set your city"
    }

    /// Writes a bar edit through the one profile write path, so it lands in
    /// Firestore and in the public projection like any other edit. A no-op
    /// edit is dropped rather than costing a round trip.
    private func save(_ edit: (inout Profile) -> Void) async {
        guard let original = session.user?.profile else { return }
        var profile = original
        edit(&profile)
        guard profile != original else { return }
        await session.updateProfile(profile)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HeroSkeleton()
                .padding(.horizontal, Space.gutter)

        // An empty pool is not a failure, and it is the one error case whose
        // answer is a call rather than a retry.
        case .failed(.noUsersAvailable):
            nobodyAroundCard
                .padding(.horizontal, Space.gutter)

        case .failed(let error):
            DiscoverMessageCard(
                icon: error.cardIcon,
                title: error.cardTitle,
                message: error.errorDescription ?? "",
                actionTitle: "Try again"
            ) {
                Task { await model.load() }
            }
            .padding(.horizontal, Space.gutter)

        case .loaded(let state):
            if let featured = state.featured {
                HeroCard(featured: featured, nearby: state.nearby) {
                    coordinator.start(mode: .video, with: featured)
                }
                .padding(.horizontal, Space.gutter)
            } else {
                nobodyAroundCard
                    .padding(.horizontal, Space.gutter)
            }
        }
    }

    /// Nobody to put in the hero — but Discover must never be a screen with
    /// no way into a call. Nearby is that way in both states: over a hero it
    /// rings the person it just named, and here it joins the queue and waits
    /// for whoever turns up next. Same button, same identifier, one promise.
    ///
    /// Refreshing is what the card used to offer instead, and it is not lost:
    /// pulling down the screen still reloads the feed. Getting in the queue
    /// is the better answer to an empty room, so it is the one on the card.
    private var nobodyAroundCard: some View {
        DiscoverMessageCard(
            icon: "person.2.slash",
            title: "No one's around",
            message: "Nobody's waiting right now. Tap Nearby and we'll pair you with the first person who's free.",
            actionTitle: "Nearby",
            actionIdentifier: "discover.nearby"
        ) {
            coordinator.start(mode: .video)
        }
    }

    /// The two chat modes. Both are video calls on the one matchmaking pool —
    /// the experience decides what the live screen offers, never the
    /// transport and never a separate queue. Neither is an audio-only start:
    /// `.voice` is decode-only and has no button anywhere.
    private var chatModes: some View {
        HStack(spacing: Space.tileGap) {
            ChatModeTile(
                title: "Video Match",
                subtitle: "Instant video conversations",
                icon: "video.fill",
                iconColor: Palette.mascotPinkInk,
                gradient: Palette.videoPink,
                mascotColor: Palette.mascotPink
            ) {
                coordinator.start(mode: .video, experience: .videoMatch)
            }
            .accessibilityIdentifier("discover.videoMatch")

            ChatModeTile(
                title: "Go Play",
                subtitle: "Match, talk, then pick a game.",
                icon: "gamecontroller.fill",
                iconColor: Palette.mascotSageInk,
                gradient: Palette.goPlaySage,
                mascotColor: Palette.mascotSage
            ) {
                // Go Play is a video call you choose a game inside — never an
                // audio-only call, and never a different queue. The experience
                // decides what the live screen offers; the transport is the
                // ordinary video flow.
                coordinator.start(mode: .video, experience: .goPlay)
            }
            .accessibilityIdentifier("discover.goPlay")
        }
    }

    /// A call is running behind this screen — one tap back into it.
    private var returnToCallBanner: some View {
        Button {
            coordinator.resume()
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "phone.fill")
                    .font(.system(size: Size.iconMedium))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Call in progress")
                        .font(Typography.rowTitleSmall)
                        .foregroundStyle(.white)
                    if let candidate = coordinator.flow?.candidate {
                        Text("with \(candidate.displayName) — tap to return")
                            .font(Typography.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(Space.md)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.online)
            )
            .shadow(Shadows.card)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to your call in progress")
        .accessibilityIdentifier("discover.returnToCall")
    }
}

/// Card presentation per failure state. View-layer on purpose: the error
/// enum owns the words (errorDescription), the view owns the pictures — and
/// only genuine connectivity loss gets the wifi-slash "You're offline" card.
private extension DiscoveryError {
    var cardIcon: String {
        switch self {
        case .offline: "wifi.slash"
        case .noUsersAvailable: "person.2.slash"
        case .rateLimited: "hourglass"
        case .sessionExpired: "person.crop.circle.badge.exclamationmark"
        case .loadFailed: "exclamationmark.bubble"
        }
    }

    var cardTitle: String {
        switch self {
        case .offline: "You're offline"
        case .noUsersAvailable: "No one's around"
        case .rateLimited: "One moment"
        // The auth listener signs the dead session out and routes to
        // welcome on its own; this card covers the beat in between.
        case .sessionExpired: "Signed out"
        case .loadFailed: "Something went wrong"
        }
    }
}
