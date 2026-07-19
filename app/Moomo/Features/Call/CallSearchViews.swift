import SwiftUI

// MARK: - Searching

/// Matchmaking in progress: pulsing rings on the night background, with the
/// only honest action available — backing out.
struct CallSearchingView: View {
    var mode: CallMode
    var onCancel: () -> Void

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(Palette.blue.opacity(0.4 - Double(index) * 0.1), lineWidth: 1.5)
                        .frame(
                            width: 150 + CGFloat(index) * 60,
                            height: 150 + CGFloat(index) * 60
                        )
                        .scaleEffect(pulse ? 1.08 : 0.94)
                }

                Circle()
                    .fill(Palette.nightRaised)
                    .frame(width: 110, height: 110)

                Image(systemName: mode.icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Palette.textOnDark)
            }
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(Motion.ambient) { pulse = true }
            }

            Text("Finding someone…")
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.textOnDark)
                .padding(.top, Space.xxl)

            Text(mode == .video
                 ? "Matching you for an instant video chat."
                 : "Matching you for a real voice conversation.")
                .font(Typography.body)
                .foregroundStyle(Palette.textOnDarkSecondary)
                .padding(.top, Space.xxs)

            Spacer()

            Button("Cancel", action: onCancel)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textOnDarkSecondary)
                .padding(.bottom, Space.xxl)
                .accessibilityIdentifier("call.cancelSearch")
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Connecting

/// Someone was found — show who while the call is established. Deliberately
/// no cancel: this phase lasts under a second and a cancel here would race
/// the connection.
struct CallConnectingView: View {
    var candidate: DiscoveryCandidate
    var mode: CallMode

    var body: some View {
        VStack(spacing: Space.md) {
            Spacer()

            AvatarView(name: candidate.displayName, photoPath: candidate.photoPath, size: Size.heroAvatar * 0.7)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 5))
                .shadow(Shadows.avatar)

            VStack(spacing: Space.xxs) {
                Text("\(candidate.displayName), \(candidate.age)")
                    .font(Typography.heroTitle)
                    .foregroundStyle(Palette.textOnDark)

                Text(candidate.city)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textOnDarkSecondary)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: Space.xs) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Palette.textOnDarkSecondary)
                Text("Connecting…")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textOnDarkSecondary)
            }
            .padding(.top, Space.sm)

            Spacer()
        }
    }
}
