import SwiftUI

/// Welcome / authentication — the app's first screen.
///
/// Matches reference 1. Layout notes taken from the reference:
/// • Logo is optically centred in the upper two-thirds, not the whole screen.
/// • Sparkles are asymmetric: a blue one above the arc with a small gold one
///   tucked beneath it, and a lone gold one off the arc's right shoulder.
/// • The three auth rows are evenly spaced with a 14pt gap.
/// • Page dots sit below the last button, the active one a blue sparkle.
struct WelcomeView: View {
    @State private var hasConsented = false
    @State private var legalDocument: LegalDocument?
    /// Incremented to bounce the consent row when sign-in is attempted without it.
    @State private var consentNudge: CGFloat = 0
    /// Set once consent is given and a provider is chosen; consumed in Phase 3.
    @State private var pendingProvider: AuthProvider?

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()

            // Vertical rhythm is measured off the reference rather than left to
            // flexible spacers, which pack the logo into the Dynamic Island on
            // tall devices. The one flexible gap sits above the page dots, so
            // shorter screens compress there and nothing else shifts.
            VStack(spacing: 0) {
                logoBlock
                    .padding(.top, 88)

                Text("Your way to smarter, happier connections.")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 44)

                SparkleDivider()
                    .padding(.top, 20)

                ConsentRow(
                    isChecked: $hasConsented,
                    onOpenPrivacy: { legalDocument = .privacy },
                    onOpenTerms: { legalDocument = .terms }
                )
                .modifier(NudgeEffect(animatableData: consentNudge))
                .padding(.horizontal, Space.gutter)
                .padding(.top, 28)

                authButtons
                    .padding(.top, 18)

                Spacer(minLength: Space.md)

                PageDots(count: 7, activeIndex: 3)
                    .padding(.bottom, 14)
            }
        }
        .sheet(item: $legalDocument) { document in
            LegalDocumentView(document: document)
        }
    }

    private var logoBlock: some View {
        ZStack {
            MoomoLogo()

            // Blue sparkle above the arc, with its gold companion beneath.
            VStack(spacing: 2) {
                SparkleMark(size: 22, color: Palette.blue)
                SparkleMark(size: 13, color: Palette.gold.opacity(0.7))
            }
            .offset(y: -Size.logoDiameter / 2 - 26)

            // Lone gold sparkle off the arc's right shoulder.
            SparkleMark(size: 18, color: Palette.gold)
                .offset(x: Size.logoDiameter / 2 + 12, y: 22)
        }
    }

    private var authButtons: some View {
        VStack(spacing: Space.cardGap) {
            AuthButton(title: "Continue with Google", isGated: !hasConsented) {
                GoogleGlyph()
            } action: {
                signIn(with: .google)
            }

            AuthButton(title: "Continue with Apple", isGated: !hasConsented) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 22))
                    .foregroundStyle(.black)
            } action: {
                signIn(with: .apple)
            }

            AuthButton(title: "Continue as Guest", isGated: !hasConsented) {
                Image(systemName: "person.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.blue.opacity(0.75))
            } action: {
                signIn(with: .guest)
            }
        }
        .padding(.horizontal, Space.gutter)
    }

    /// The consent gate. Sign-in is refused outright without consent — the
    /// checkbox bounces and announces itself rather than the tap silently
    /// doing nothing.
    private func signIn(with provider: AuthProvider) {
        guard hasConsented else {
            withAnimation(Motion.tap) { consentNudge += 1 }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            UIAccessibility.post(
                notification: .announcement,
                argument: "Please agree to the Privacy Policy and Terms of Service first"
            )
            return
        }
        // AuthService is wired in Phase 3; consent is recorded alongside the
        // account so we can prove when and to which document version it was given.
        pendingProvider = provider
    }
}

/// The three ways into the app.
enum AuthProvider {
    case google
    case apple
    case guest
}

/// Nudges its content side to side. Used to draw the eye back to the consent
/// checkbox when someone taps sign-in without ticking it.
struct NudgeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let travel = 7 * sin(animatableData * .pi * 3)
        return ProjectionTransform(CGAffineTransform(translationX: travel, y: 0))
    }
}

/// Page indicator. The active dot is a sparkle rather than a circle, matching
/// the reference.
struct PageDots: View {
    var count: Int
    var activeIndex: Int

    var body: some View {
        HStack(spacing: Space.sm) {
            ForEach(0..<count, id: \.self) { index in
                if index == activeIndex {
                    SparkleMark(size: 14, color: Palette.blue)
                } else {
                    Circle()
                        .fill(Palette.textTertiary.opacity(0.5))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    WelcomeView()
}
