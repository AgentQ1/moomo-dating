import SwiftUI

/// Discover home. Matches reference 3.
struct DiscoverView: View {
    @EnvironmentObject private var session: SessionStore
    @ObservedObject var model: DiscoverModel
    @ObservedObject var notifications: NotificationsModel
    @ObservedObject var boost: BoostModel
    @ObservedObject var coordinator: CallCoordinator

    @State private var isShowingNotifications = false
    @State private var isShowingBoost = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DiscoverHeader(
                    name: session.user?.profile.displayName ?? "",
                    community: model.state?.community,
                    hasUnread: notifications.hasUnread,
                    isBoosted: boost.state.isActive(),
                    onBell: { isShowingNotifications = true },
                    onBoost: { isShowingBoost = true }
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
        .sheet(isPresented: $isShowingNotifications) {
            NotificationsView(model: notifications)
        }
        .sheet(isPresented: $isShowingBoost) {
            BoostView(model: boost)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HeroSkeleton()
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
                HeroCard(featured: featured, nearby: state.nearby, level: state.level) {
                    coordinator.start(mode: .video, with: featured)
                }
                .padding(.horizontal, Space.gutter)
            } else {
                DiscoverMessageCard(
                    icon: "person.2.slash",
                    title: "No one's around",
                    message: "Nobody's waiting right now. Try a chat mode below, or check back in a bit.",
                    actionTitle: "Refresh"
                ) {
                    Task { await model.load() }
                }
                .padding(.horizontal, Space.gutter)
            }
        }
    }

    private var chatModes: some View {
        HStack(spacing: Space.tileGap) {
            ChatModeTile(
                title: "Video Match",
                subtitle: "Instant video conversations",
                icon: "video.fill",
                iconColor: Color(hex: 0xEC4899),
                gradient: Palette.videoPink,
                mascotColor: Color(hex: 0xF9A8D4)
            ) {
                coordinator.start(mode: .video)
            }

            ChatModeTile(
                title: "Real Talk",
                subtitle: "Voice chats with real people",
                icon: "mic.fill",
                iconColor: Color(hex: 0x7C3AED),
                gradient: Palette.voicePurple,
                mascotColor: Color(hex: 0xC4B5FD)
            ) {
                coordinator.start(mode: .voice)
            }
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

// MARK: - Header

private struct DiscoverHeader: View {
    var name: String
    var community: String?
    var hasUnread: Bool
    var isBoosted: Bool
    var onBell: () -> Void
    var onBoost: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Hey there 👋")
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.ink)

                if let community {
                    // Informational, not a button: the community switcher
                    // arrives with the communities feature, and a chevron that
                    // goes nowhere is a broken promise.
                    HStack(spacing: Space.xxs) {
                        Image(systemName: "graduationcap.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.blue)
                        Text(community)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            // The reference keeps this on one line; long
                            // community names shrink rather than wrap,
                            // which would push the hero card down.
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Community: \(community)")
                }
            }

            Spacer(minLength: Space.xs)

            HStack(spacing: Space.xs) {
                TopActionButton(icon: "bell", showsDot: hasUnread, action: onBell)
                    .accessibilityLabel(hasUnread ? "Notifications, unread" : "Notifications")
                    .accessibilityIdentifier("discover.bell")

                Button(action: onBoost) {
                    HStack(spacing: 5) {
                        Image(systemName: isBoosted ? "bolt.circle.fill" : "bolt.circle")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(isBoosted ? Palette.gold : Palette.ink)
                        Text("Boost")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.sm)
                    .frame(height: Size.topActionButton)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                            .fill(Palette.surface)
                    )
                    .shadow(Shadows.card)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isBoosted ? "Boost, active" : "Boost")
                .accessibilityIdentifier("discover.boost")
            }
        }
    }
}

private struct TopActionButton: View {
    var icon: String
    var showsDot: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                    .fill(Palette.surface)
                    .frame(width: Size.topActionButton, height: Size.topActionButton)
                    .shadow(Shadows.card)

                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.ink)

                if showsDot {
                    Circle()
                        .fill(Palette.notificationDot)
                        .frame(width: 9, height: 9)
                        .offset(x: 11, y: -11)
                }
            }
        }
        .buttonStyle(.plain)
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
