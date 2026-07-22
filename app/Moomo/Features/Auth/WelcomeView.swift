import SwiftUI

/// Welcome / sign-in — the app's first screen. Phone OTP is the only way in:
/// enter a number, receive an SMS code, type it, signed in.
///
/// Layout notes from the reference (402pt design width):
/// • Top bar: an X on the left, "Trouble logging in?" on the right.
/// • Three overlapping circular photos, the middle one on top, centred at
///   ~y194; the headline sits ~40pt beneath them.
/// • Phone row (+1 ⌄ │ ☎ Enter phone number) over a hairline, then the coral
///   "Verification" capsule.
/// • Consent checkbox paragraph with coral links, pager dots at the bottom
///   with the fourth dot active in coral.
///
/// The button renders at full strength before consent — as the reference
/// shows — and validates the checkbox on tap instead.
struct WelcomeView: View {
    @StateObject private var phone: PhoneAuthModel

    @State private var hasConsented = false
    @State private var legalDocument: LegalDocument?
    @State private var isShowingLoginHelp = false
    @FocusState private var isPhoneFocused: Bool

    init(auth: AuthenticationService) {
        _phone = StateObject(wrappedValue: PhoneAuthModel(auth: auth))
    }

    var body: some View {
        ZStack {
            Palette.blush.ignoresSafeArea()
            watermarks

            GeometryReader { proxy in
                ScrollView {
                    content
                        // Fill the screen so the pager dots sit at the bottom
                        // on tall devices; shorter screens scroll instead.
                        .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .sheet(item: $legalDocument) { document in
            LegalDocumentView(document: document)
        }
        .fullScreenCover(isPresented: showingOTP) {
            OTPEntryView(model: phone)
        }
        .alert("Trouble logging in?", isPresented: $isShowingLoginHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Make sure you can receive SMS at your number. Still stuck? Email moomolab@gmail.com.")
        }
        .onDisappear { phone.cancel() }
        .animation(Motion.transition, value: phone.error)
    }

    private var content: some View {
        VStack(spacing: 0) {
            topBar

            avatarCluster
                .padding(.top, 56)

            Text("Find the person nearby you'd most like to meet")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                // One line, as the reference sets it — scaled a touch rather
                // than wrapped when the width is tight.
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, Space.md)
                .padding(.top, 44)

            PhoneEntryRow(model: phone, isFocused: $isPhoneFocused)
                .padding(.horizontal, Space.xl + 6)
                .padding(.top, 44)

            PhoneFlowErrorText(error: phone.error)
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.sm)

            VerificationButton(isLoading: phone.stage == .sendingCode) {
                isPhoneFocused = false
                phone.sendCode(hasConsented: hasConsented)
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, 30)

            ConsentRow(
                isChecked: $hasConsented,
                onOpenPrivacy: { legalDocument = .privacy },
                onOpenTerms: { legalDocument = .terms }
            )
            .padding(.horizontal, Space.xl + 4)
            .padding(.top, 34)

            Spacer(minLength: Space.xxl)

            PageDots(count: 7, activeIndex: 3)
                .padding(.bottom, Space.md)
        }
    }

    /// The OTP screen is up from the moment the SMS is out until sign-in
    /// succeeds (routing then replaces this screen entirely) or the user
    /// backs out to edit the number.
    private var showingOTP: Binding<Bool> {
        Binding(
            get: { phone.stage == .codeSent || phone.stage == .verifying },
            set: { if !$0 { phone.editNumber() } }
        )
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Spacer()

            Button("Trouble logging in?") {
                isShowingLoginHelp = true
            }
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Palette.ink)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Space.md)
        .padding(.top, Space.xs)
    }

    /// Faint outlined glyphs scattered over the blush background, as in the
    /// reference. Decorative only.
    private var watermarks: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack {
                Image(systemName: "play")
                    .font(.system(size: 64, weight: .ultraLight))
                    .rotationEffect(.degrees(-14))
                    .position(x: w * 0.27, y: 150)
                Image(systemName: "plus")
                    .font(.system(size: 56, weight: .thin))
                    .position(x: w * 0.76, y: 215)
                Image(systemName: "play")
                    .font(.system(size: 44, weight: .ultraLight))
                    .rotationEffect(.degrees(10))
                    .position(x: w * 0.10, y: 320)
                Image(systemName: "circle")
                    .font(.system(size: 48, weight: .thin))
                    .position(x: w * 0.94, y: 375)
            }
            .foregroundStyle(Palette.flamingo.opacity(0.05))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: - Avatars

    /// Left and right circles tucked beneath the middle one, as the reference
    /// overlaps them.
    private var avatarCluster: some View {
        ZStack {
            avatar("welcome-avatar-1")
                .offset(x: -59)
            avatar("welcome-avatar-3")
                .offset(x: 59)
            avatar("welcome-avatar-2")
        }
        .accessibilityHidden(true)
    }

    private func avatar(_ name: String) -> some View {
        Image(name)
            .resizable()
            .scaledToFill()
            .frame(width: 63, height: 63)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

}

/// Page indicator. The active dot is a coral diamond, matching the reference.
struct PageDots: View {
    var count: Int
    var activeIndex: Int

    var body: some View {
        HStack(spacing: Space.sm) {
            ForEach(0..<count, id: \.self) { index in
                if index == activeIndex {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(Palette.flamingo)
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(45))
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
    WelcomeView(auth: MockAuthenticationService())
}
