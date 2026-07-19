import SwiftUI

// MARK: - Phone entry row

/// The phone input row from the welcome reference: dial code with a chevron,
/// a hairline divider, a receiver glyph, and the number field — underlined.
struct PhoneEntryRow: View {
    @ObservedObject var model: PhoneAuthModel
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                countrySelector

                Rectangle()
                    .fill(Palette.separator)
                    .frame(width: 1, height: 30)

                Image(systemName: "phone.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.textTertiary)
                    .padding(.leading, Space.xs)

                TextField("Enter phone number", text: $model.nationalNumber)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Palette.ink)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused(isFocused)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("phone.number")
            }

            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
        }
    }

    private var countrySelector: some View {
        Menu {
            ForEach(CountryDialCode.all) { country in
                Button {
                    model.countryCode = country
                } label: {
                    Text("\(country.flag) \(country.name) (\(country.dialCode))")
                }
            }
        } label: {
            HStack(spacing: Space.xxs) {
                Text(model.countryCode.dialCode)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
        }
        .disabled(model.isBusy)
        .accessibilityLabel("Country code \(model.countryCode.name) \(model.countryCode.dialCode)")
    }
}

/// The coral "Verification" CTA beneath the phone row.
struct VerificationButton: View {
    var isLoading: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: "iphone")
                        .font(.system(size: 18, weight: .medium))
                    Text("Verification")
                        .font(.system(size: 19, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Capsule().fill(Palette.flamingo))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel("Verification")
        .accessibilityValue(isLoading ? "Sending code" : "")
    }
}

/// Inline error line for the phone flow. Global alerts are for app failures;
/// a mistyped number or code is part of the flow and belongs on the screen.
struct PhoneFlowErrorText: View {
    var error: AuthError?

    var body: some View {
        if let message = error?.errorDescription {
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.notificationDot)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}

// MARK: - OTP entry

/// The code screen shown after the SMS goes out. Six boxes over a hidden
/// field; verifies automatically at the sixth digit.
struct OTPEntryView: View {
    @ObservedObject var model: PhoneAuthModel

    @FocusState private var isCodeFocused: Bool

    var body: some View {
        ZStack {
            Palette.blush.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Text("Enter your code")
                    .font(Typography.heroTitle)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, Space.xxl)

                Text("We sent an SMS to \(model.sentToNumber)")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, Space.xs)

                codeBoxes
                    .padding(.top, Space.xxl)

                PhoneFlowErrorText(error: model.error)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.md)

                if model.stage == .verifying {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Palette.flamingo)
                        .padding(.top, Space.lg)
                }

                resendButton
                    .padding(.top, Space.lg)

                Spacer(minLength: Space.md)
            }
        }
        .onAppear { isCodeFocused = true }
        .animation(Motion.transition, value: model.error)
        .animation(Motion.transition, value: model.stage)
    }

    private var header: some View {
        HStack {
            Button {
                model.editNumber()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: Size.minTapTarget, height: Size.minTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change phone number")

            Spacer()
        }
        .padding(.horizontal, Space.sm)
    }

    /// The visible boxes mirror an invisible text field stretched over them —
    /// the field owns the keyboard, so tapping anywhere on the boxes focuses
    /// it, and paste and the system SMS autofill both just work.
    private var codeBoxes: some View {
        HStack(spacing: Space.sm) {
            ForEach(0..<PhoneAuthModel.codeLength, id: \.self) { index in
                digitBox(at: index)
            }
        }
        .overlay {
            TextField("", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isCodeFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .opacity(0.05)
                .accessibilityIdentifier("otp.code")
                .onChange(of: model.code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(PhoneAuthModel.codeLength))
                    if digits != newValue {
                        model.code = digits
                        return
                    }
                    if digits.count == PhoneAuthModel.codeLength {
                        model.verifyCode()
                    }
                }
        }
    }

    private func digitBox(at index: Int) -> some View {
        let digits = Array(model.code)
        let isActive = index == digits.count && isCodeFocused

        return RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
            .fill(Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                    .stroke(
                        isActive ? Palette.flamingo : Palette.separator,
                        lineWidth: isActive ? 2 : 1
                    )
            )
            .overlay {
                if index < digits.count {
                    Text(String(digits[index]))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
            .frame(width: 48, height: 56)
    }

    private var resendButton: some View {
        Button {
            model.resendCode()
        } label: {
            Text(
                model.isResending
                    ? "Sending…"
                    : model.resendCooldown > 0
                        ? "Resend code in \(model.resendCooldown)s"
                        : "Resend code"
            )
            .font(Typography.rowTitle)
            .foregroundStyle(
                model.resendCooldown > 0 || model.isResending
                    ? Palette.textTertiary : Palette.flamingo
            )
        }
        .buttonStyle(.plain)
        .disabled(model.resendCooldown > 0 || model.isBusy || model.isResending)
        .accessibilityLabel("Resend code")
    }
}

