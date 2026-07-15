import SwiftUI

/// A full-width sign-in row: circular icon well on the left, centred blue
/// label, chevron-style arrow on the right.
///
/// Consent gating, and why these don't dim:
///
/// The reference shows the checkbox *unchecked* and these rows at full
/// strength, while the spec requires sign-in to be disabled until consent is
/// given. Dimming them would contradict the reference; letting them sign you
/// in would contradict the spec. So the row stays visually identical to the
/// reference and remains tappable, but a gated tap refuses the sign-in and
/// bounces the consent checkbox instead — consent is still strictly enforced,
/// and the user is told why rather than being left with a dead control.
///
/// To switch to a literal dimmed-disabled treatment, set `isGated` to drive
/// `.opacity` here; nothing else needs to change.
struct AuthButton<Icon: View>: View {
    var title: String
    /// True when consent has not yet been given. The row still renders and
    /// still accepts taps; `action` is expected to refuse.
    var isGated: Bool
    @ViewBuilder var icon: () -> Icon
    var action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(Palette.iconWell)
                        .frame(width: Size.authIconWell, height: Size.authIconWell)
                    icon()
                }
                .padding(.leading, Space.md)

                Spacer(minLength: 0)

                Text(title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.blue)

                Spacer(minLength: 0)

                Image(systemName: "arrow.right")
                    .font(.system(size: Size.iconMedium, weight: .medium))
                    .foregroundStyle(Palette.blue)
                    .padding(.trailing, Space.lg)
            }
            .frame(height: Size.authButtonHeight)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface.opacity(0.85))
            )
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
        .accessibilityLabel(title)
        .accessibilityHint(
            isGated
                ? "Agree to the Privacy Policy and Terms of Service to continue"
                : ""
        )
    }
}

/// Google's mark. Drawn rather than bundled — the real asset ships with the
/// GoogleSignIn SDK and should replace this once that package is added, since
/// Google's brand guidelines require their exact logo.
struct GoogleGlyph: View {
    var size: CGFloat = 22

    var body: some View {
        // Placeholder geometry that reads correctly at 22pt: the four-colour G.
        // Replaced by `Image("google_logo")` from GoogleSignIn in Phase 3.
        ZStack {
            Text("G")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(hex: 0x4285F4), Color(hex: 0x34A853),
                            Color(hex: 0xFBBC05), Color(hex: 0xEA4335)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    ZStack {
        Palette.cream.ignoresSafeArea()
        VStack(spacing: Space.cardGap) {
            AuthButton(title: "Continue with Google", isGated: false) {
                GoogleGlyph()
            } action: {}

            AuthButton(title: "Continue with Apple", isGated: false) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 22))
                    .foregroundStyle(.black)
            } action: {}

            AuthButton(title: "Continue as Guest", isGated: true) {
                Image(systemName: "person.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.blue)
            } action: {}
        }
        .padding(.horizontal, Space.gutter)
    }
}
