import SwiftUI

// MARK: - Hero

/// The featured-candidate card: orbiting avatars, level pill, and the primary
/// call to action.
struct HeroCard: View {
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

            Text("Start a video chat and make a real connection.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, Space.xxs)

            PrimaryButton(
                title: "Talk to \(featured.pronoun.objectForm)",
                icon: "video.fill",
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
            AvatarView(name: candidate.displayName, photoPath: candidate.photoPath, size: Size.heroAvatar)
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
        AvatarView(name: candidate.displayName, photoPath: candidate.photoPath, size: Size.orbitAvatar)
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
