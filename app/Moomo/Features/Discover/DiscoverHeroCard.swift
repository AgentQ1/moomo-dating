import SwiftUI

// MARK: - Hero

/// The featured-candidate card: orbiting avatars and the primary call to
/// action.
struct HeroCard: View {
    var featured: DiscoveryCandidate
    var nearby: [DiscoveryCandidate]
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
            .frame(height: Size.heroStage)
            .padding(.top, Space.lg)

            // Who this is, named, before the call request goes out. The card
            // used to fall back to "Someone is waiting" whenever `wantsToTalk`
            // was false, which left the one screen where the user decides to
            // call showing an anonymous face — the gap App Review asked about
            // on 2026-08-05. Identity is never optional here now, and this
            // deliberately departs from the Discover reference, which shows
            // the anonymous wording.
            //
            // Both lines are pinned to a fixed height rather than measured. A
            // font that rounds differently, or an identity line that degrades
            // to the longer fallback copy, must not be able to change how tall
            // this card is — `HeroSkeleton` is built to the same arithmetic.
            Text("\(featured.displayName), \(featured.age)")
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, Space.md)
                .frame(height: Size.heroNameLine)
                .padding(.top, Space.md)

            Text(identityLine)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, Space.md)
                .frame(height: Size.heroIdentityLine)
                .padding(.top, Space.xxs)

            PrimaryButton(
                title: "Nearby",
                icon: "video.fill",
                fill: Palette.magenta,
                action: onTalk
            )
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.md)
            .padding(.bottom, Space.lg)
            .accessibilityLabel("Nearby. Start a video call with \(featured.displayName)")
            .accessibilityIdentifier("discover.nearby")
        }
        .frame(maxWidth: .infinity, minHeight: Size.heroCardHeight)
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

    /// City and presence, under the name. Both are optional in the public
    /// projection, so the line degrades to the action copy rather than
    /// rendering an empty row.
    private var identityLine: String {
        let parts = [
            featured.city.isEmpty ? nil : featured.city,
            featured.isOnline ? "Online now" : nil
        ].compactMap { $0 }
        return parts.isEmpty
            ? "Start a video chat and make a real connection."
            : parts.joined(separator: " · ")
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
    /// 0…1, driven by the card's ambient loop.
    ///
    /// It scales the rings; it does not resize them. The distinction is the
    /// whole point: the frames used to grow with the phase, so the card was
    /// running a layout pass every frame from the moment it appeared and the
    /// rings visibly changed shape a beat after first paint. A scale is a
    /// render transform — the geometry is settled before the animation
    /// starts and stays settled while it runs.
    var phase: CGFloat

    /// Matches the old 6pt diameter swell at the outer ring.
    private static let swell: CGFloat = 0.022

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let diameter = 210 + CGFloat(index) * 34
                Circle()
                    .stroke(.white.opacity(0.55 - Double(index) * 0.15), lineWidth: 1.5)
                    .frame(width: diameter, height: diameter)
            }
        }
        .scaleEffect(1 + phase * Self.swell)
        .accessibilityHidden(true)
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
