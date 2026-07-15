import SwiftUI

/// A full-width sign-in row: circular icon well on the left, centred blue
/// label, trailing arrow. Shows a spinner in place of the arrow while its
/// provider is authenticating.
///
/// Consent gating: these are genuinely disabled until consent is given —
/// dimmed, non-tappable, and marked disabled to VoiceOver. The reference shows
/// the rows at full strength with the box unchecked, so the dimmed state is a
/// deliberate, spec-mandated departure from the reference on that one point.
struct AuthButton<Icon: View>: View {
    var title: String
    var isEnabled: Bool
    /// Shows a spinner and blocks input while this provider is signing in.
    var isLoading: Bool = false
    @ViewBuilder var icon: () -> Icon
    var action: () -> Void

    @State private var isPressed = false

    private var isInteractive: Bool { isEnabled && !isLoading }

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

                Group {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(Palette.blue)
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: Size.iconMedium, weight: .medium))
                            .foregroundStyle(Palette.blue)
                    }
                }
                .frame(width: Size.iconMedium)
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
            .opacity(isEnabled ? 1 : 0.4)
            .saturation(isEnabled ? 1 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .animation(Motion.tap, value: isPressed)
        .animation(Motion.transition, value: isEnabled)
        .animation(Motion.transition, value: isLoading)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isInteractive { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel(title)
        .accessibilityHint(
            isEnabled ? "" : "Agree to the Privacy Policy and Terms of Service to enable"
        )
        .accessibilityValue(isLoading ? "Signing in" : "")
    }
}

/// Google's mark.
///
/// Placeholder geometry. Google's brand guidelines require their exact asset,
/// which ships inside the GoogleSignIn SDK — once that package is added, this
/// becomes the bundled logo. Shipping this drawn approximation would breach
/// those guidelines.
struct GoogleGlyph: View {
    var size: CGFloat = 22

    var body: some View {
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
            .frame(width: size, height: size)
    }
}

#Preview {
    ZStack {
        Palette.cream.ignoresSafeArea()
        VStack(spacing: Space.cardGap) {
            AuthButton(title: "Continue with Google", isEnabled: true) {
                GoogleGlyph()
            } action: {}

            AuthButton(title: "Continue with Apple", isEnabled: true, isLoading: true) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 22))
                    .foregroundStyle(.black)
            } action: {}

            AuthButton(title: "Continue as Guest", isEnabled: false) {
                Image(systemName: "person.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.blue)
            } action: {}
        }
        .padding(.horizontal, Space.gutter)
    }
}
