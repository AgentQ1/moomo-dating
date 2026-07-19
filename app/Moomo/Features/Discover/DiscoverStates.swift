import SwiftUI

// MARK: - Loading and message states

/// Placeholder shown while discovery loads.
struct HeroSkeleton: View {
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

/// Offline / empty / error card with a single action.
struct DiscoverMessageCard: View {
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
