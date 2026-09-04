import SwiftUI

// MARK: - Loading and message states

/// Placeholder shown while discovery loads.
///
/// Deliberately the same shape as `HeroCard`, block for block: the same stage
/// box, the same two text lines at the same offsets, the same pill in the same
/// place, and the same `Size.heroCardHeight` overall. The feed arriving then
/// fills this card in rather than replacing it with a taller one — which is
/// what used to make Discover blink and shunt the chat-mode tiles down the
/// screen a beat after it opened.
struct HeroSkeleton: View {
    @State private var shimmer = false

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(.white.opacity(0.5))
                .frame(width: Size.heroAvatar, height: Size.heroAvatar)
                .frame(height: Size.heroStage)
                .padding(.top, Space.lg)

            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.55))
                .frame(width: 190, height: 22)
                .frame(height: Size.heroNameLine)
                .padding(.top, Space.md)

            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.4))
                .frame(width: 240, height: 14)
                .frame(height: Size.heroIdentityLine)
                .padding(.top, Space.xxs)

            Capsule()
                .fill(.white.opacity(0.5))
                .frame(height: Size.primaryCTAHeight)
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.md)
                .padding(.bottom, Space.lg)
        }
        .frame(maxWidth: .infinity, minHeight: Size.heroCardHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardLarge, style: .continuous)
                .fill(Palette.heroPeach)
        )
        // The loaded card carries this too. A shadow appearing along with the
        // content is a second thing changing about the card's outline.
        .shadow(Shadows.cardLarge)
        // Opacity only: an ambient loop on this screen may not touch layout.
        .opacity(shimmer ? 0.65 : 1)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
        .accessibilityLabel("Loading")
    }
}

/// Offline / empty / error card with a single action.
///
/// Stands as tall as the hero it stands in for, for the same reason the
/// skeleton does: loading → "no one's around" must not resize the card or move
/// anything below it.
struct DiscoverMessageCard: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String
    /// Accessibility identifier for the action button. The "no one's around"
    /// card's action is Nearby, and it has to be findable by the same name as
    /// the hero's Nearby — they are the one way into a call, in the two
    /// states Discover can be in.
    var actionIdentifier: String?
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
                .accessibilityIdentifier(actionIdentifier ?? "")
        }
        .frame(maxWidth: .infinity, minHeight: Size.heroCardHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardLarge, style: .continuous)
                .fill(Palette.heroPeach)
        )
        .shadow(Shadows.cardLarge)
        .accessibilityElement(children: .contain)
    }
}
