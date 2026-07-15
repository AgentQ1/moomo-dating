import SwiftUI

/// Welcome / authentication — the app's first screen. Matches reference 1.
///
/// Layout notes from the reference:
/// • The logo is optically centred in the upper two-thirds, not the screen.
/// • Sparkles are asymmetric: a blue one above the arc with a small gold one
///   beneath it, and a lone gold one in the arc's right-hand opening.
/// • Three auth rows, 14pt apart.
/// • Page dots below, the active one a blue sparkle.
struct WelcomeView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var hasConsented = false
    @State private var legalDocument: LegalDocument?

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
            LogoMark()

            // Blue sparkle above the arc, with its gold companion beneath.
            VStack(spacing: 2) {
                SparkleMark(size: 22, color: Palette.blue)
                SparkleMark(size: 13, color: Palette.gold.opacity(0.7))
            }
            .offset(y: -Size.logoDiameter / 2 - 26)

            // Lone gold sparkle in the arc's opening.
            SparkleMark(size: 18, color: Palette.gold)
                .offset(x: Size.logoDiameter / 2 + 12, y: 22)
        }
        .accessibilityHidden(true)
    }

    private var authButtons: some View {
        VStack(spacing: Space.cardGap) {
            AuthButton(
                title: "Continue with Google",
                isEnabled: hasConsented,
                isLoading: session.signingInWith == .google
            ) {
                GoogleGlyph()
            } action: {
                session.signIn(with: .google, hasConsented: hasConsented)
            }

            AuthButton(
                title: "Continue with Apple",
                isEnabled: hasConsented,
                isLoading: session.signingInWith == .apple
            ) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 22))
                    .foregroundStyle(.black)
            } action: {
                session.signIn(with: .apple, hasConsented: hasConsented)
            }

            AuthButton(
                title: "Continue as Guest",
                isEnabled: hasConsented,
                isLoading: session.signingInWith == .guest
            ) {
                Image(systemName: "person.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.blue.opacity(0.75))
            } action: {
                session.signIn(with: .guest, hasConsented: hasConsented)
            }
        }
        .padding(.horizontal, Space.gutter)
        .accessibilityElement(children: .contain)
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
        .environmentObject(SessionStore(auth: MockAuthenticationService()))
}
