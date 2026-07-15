import SwiftUI

/// Discover home. Matches reference 3.
struct DiscoverView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var model = DiscoverModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DiscoverHeader(
                    name: session.user?.profile.displayName ?? "",
                    community: model.state?.community,
                    hasUnread: model.state?.hasUnreadNotifications ?? false
                )
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.xs)

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
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HeroSkeleton()
                .padding(.horizontal, Space.gutter)

        case .failed(let error):
            DiscoverMessageCard(
                icon: error == .offline ? "wifi.slash" : "person.2.slash",
                title: error == .offline ? "You're offline" : "No one's around",
                message: error.errorDescription ?? "",
                actionTitle: "Try again"
            ) {
                Task { await model.load() }
            }
            .padding(.horizontal, Space.gutter)

        case .loaded(let state):
            if let featured = state.featured {
                HeroCard(featured: featured, nearby: state.nearby, level: state.level) {
                    model.startCall(with: featured)
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
                model.startMode(.video)
            }

            ChatModeTile(
                title: "Real Talk",
                subtitle: "Voice chats with real people",
                icon: "mic.fill",
                iconColor: Color(hex: 0x7C3AED),
                gradient: Palette.voicePurple,
                mascotColor: Color(hex: 0xC4B5FD)
            ) {
                model.startMode(.voice)
            }
        }
    }
}

// MARK: - Header

private struct DiscoverHeader: View {
    var name: String
    var community: String?
    var hasUnread: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Hey there 👋")
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.ink)

                if let community {
                    Button {
                        // Community switcher lands with the communities feature.
                    } label: {
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
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Change community")
                }
            }

            Spacer(minLength: Space.xs)

            HStack(spacing: Space.xs) {
                TopActionButton(icon: "bell", showsDot: hasUnread) {}
                    .accessibilityLabel(hasUnread ? "Notifications, unread" : "Notifications")

                Button {} label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.circle")
                            .font(.system(size: 19, weight: .medium))
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

// MARK: - Hero

private struct HeroCard: View {
    var featured: DiscoveryCandidate
    var nearby: [DiscoveryCandidate]
    var level: Int
    var onTalk: () -> Void

    @State private var ringPhase: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                OrbitRings(phase: ringPhase)

                ForEach(Array(nearby.prefix(5).enumerated()), id: \.element.id) { index, person in
                    OrbitAvatar(candidate: person)
                        .offset(orbitOffset(for: index, of: min(nearby.count, 5)))
                }

                FeaturedAvatar(candidate: featured)

                if featured.wantsToTalk {
                    SpeechBubble(text: "Wants to\nTalk to You")
                        .offset(x: 74, y: -84)
                }
            }
            .frame(height: 260)
            .padding(.top, Space.lg)
            .overlay(alignment: .topLeading) {
                LevelPill(level: level)
                    .padding(.leading, Space.md)
                    .padding(.top, Space.md)
            }

            Text("Someone is waiting")
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.ink)
                .padding(.top, Space.md)

            Text("Start a voice chat and make a real connection.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, Space.xxs)

            PrimaryButton(
                title: "Talk to \(featured.pronoun.objectForm)",
                icon: "phone.fill",
                action: onTalk
            )
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.md)
            .padding(.bottom, Space.lg)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.cardLarge, style: .continuous)
                .fill(Palette.heroPeach)
        )
        .overlay(alignment: .topTrailing) {
            SparkleMark(size: 12, color: .white.opacity(0.9))
                .offset(x: -Space.xl, y: 90)
        }
        .shadow(Shadows.cardLarge)
        .onAppear {
            withAnimation(Motion.ambient) { ringPhase = 1 }
        }
    }

    /// Places the orbiting avatars around the hero: three down the left, three
    /// on the right, matching the reference's asymmetric arrangement.
    ///
    /// The first right-hand slot sits low enough to clear the "Wants to Talk
    /// to You" bubble, which occupies the upper right of the card.
    private func orbitOffset(for index: Int, of count: Int) -> CGSize {
        let positions: [CGSize] = [
            CGSize(width: -134, height: -56),
            CGSize(width: -150, height: 48),
            CGSize(width: 140, height: 26),
            CGSize(width: 132, height: 116),
            CGSize(width: -120, height: 132)
        ]
        return positions[safe: index] ?? .zero
    }
}

private struct FeaturedAvatar: View {
    var candidate: DiscoveryCandidate

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AvatarView(name: candidate.displayName, size: Size.heroAvatar)
                .overlay(Circle().stroke(.white, lineWidth: 6))
                .shadow(Shadows.avatar)

            if candidate.isOnline {
                Circle()
                    .fill(Palette.online)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(.white, lineWidth: 4))
                    .offset(x: -12, y: -8)
            }
        }
        .frame(width: Size.heroAvatar, height: Size.heroAvatar)
        .accessibilityElement()
        .accessibilityLabel(
            "\(candidate.displayName), \(candidate.age)"
            + (candidate.isOnline ? ", online" : "")
            + (candidate.wantsToTalk ? ", wants to talk to you" : "")
        )
    }
}

private struct OrbitAvatar: View {
    var candidate: DiscoveryCandidate

    var body: some View {
        AvatarView(name: candidate.displayName, size: Size.orbitAvatar)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: Palette.ink.opacity(0.10), radius: 8, y: 3)
            .accessibilityHidden(true)
    }
}

/// The concentric rings behind the hero avatar, breathing slowly.
private struct OrbitRings: View {
    var phase: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(.white.opacity(0.55 - Double(index) * 0.15), lineWidth: 1.5)
                    .frame(
                        width: 210 + CGFloat(index) * 34 + phase * 6,
                        height: 210 + CGFloat(index) * 34 + phase * 6
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LevelPill: View {
    var level: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("🔥").font(.system(size: 13))
            Text("Lv. \(level)")
                .font(Typography.pill)
                .foregroundStyle(Palette.coral)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 7)
        .background(Capsule().fill(Palette.surface))
        .shadow(Shadows.card)
        .accessibilityLabel("Level \(level)")
    }
}

private struct SpeechBubble: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Typography.speechBubble)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                    .fill(Palette.coral)
            )
            .rotationEffect(.degrees(-8))
            .shadow(color: Palette.coral.opacity(0.3), radius: 10, y: 4)
            .accessibilityHidden(true)
    }
}

// MARK: - Chat modes

private struct ChatModeTile: View {
    var title: String
    var subtitle: String
    var icon: String
    var iconColor: Color
    var gradient: LinearGradient
    var mascotColor: Color
    var action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)

                Text(subtitle)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xxs)

                Spacer(minLength: Space.sm)

                ZStack {
                    Circle()
                        .fill(.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Size.chatModeTileHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(gradient)
            )
            .overlay(alignment: .bottomTrailing) {
                Mascot(color: mascotColor)
                    .frame(width: 92, height: 92)
                    .padding(.trailing, -6)
                    .padding(.bottom, -4)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .shadow(Shadows.card)
            .scaleEffect(isPressed ? Motion.pressedScale : 1)
        }
        .buttonStyle(.plain)
        .animation(Motion.tap, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

/// The blob mascot in the corner of each chat-mode tile.
///
/// Placeholder geometry approximating the reference's character. Like the
/// logo, these are illustrations that should come from the designer as assets
/// rather than be drawn in code.
private struct Mascot: View {
    var color: Color

    var body: some View {
        ZStack {
            Ellipse()
                .fill(color)
                .frame(width: 66, height: 74)
                .offset(y: 8)

            // Eyes
            HStack(spacing: 12) {
                eye
                eye
            }
            .offset(y: -4)

            // Arms
            Capsule()
                .fill(color)
                .frame(width: 26, height: 13)
                .rotationEffect(.degrees(24))
                .offset(x: -34, y: 20)
        }
    }

    private var eye: some View {
        ZStack {
            Circle().fill(Palette.ink).frame(width: 9, height: 9)
            Circle().fill(.white).frame(width: 3, height: 3).offset(x: 1, y: -1.5)
        }
    }
}

// MARK: - States

private struct HeroSkeleton: View {
    @State private var shimmer = false

    var body: some View {
        VStack(spacing: Space.md) {
            Circle()
                .fill(.white.opacity(0.55))
                .frame(width: Size.heroAvatar, height: Size.heroAvatar)
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.55))
                .frame(width: 190, height: 22)
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.4))
                .frame(width: 240, height: 14)
            Capsule()
                .fill(.white.opacity(0.5))
                .frame(height: Size.primaryCTAHeight)
                .padding(.horizontal, Space.xxl)
        }
        .padding(.vertical, Space.xl)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardLarge, style: .continuous)
                .fill(Palette.heroPeach)
        )
        .opacity(shimmer ? 0.65 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        .accessibilityLabel("Loading")
    }
}

private struct DiscoverMessageCard: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, Space.lg)

            Text(title)
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.ink)

            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.lg)

            PrimaryButton(title: actionTitle, action: action)
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.lg)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardLarge, style: .continuous)
                .fill(Palette.heroPeach)
        )
        .shadow(Shadows.cardLarge)
        .accessibilityElement(children: .contain)
    }
}
