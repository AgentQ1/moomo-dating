import Foundation
import SwiftUI

/// A dial code the country selector offers. A curated list, not ISO-complete:
/// the menu needs to be scannable, and the backend validates the number
/// properly server-side regardless.
struct CountryDialCode: Identifiable, Equatable {
    let flag: String
    let name: String
    /// E.164 prefix including the plus, e.g. "+1".
    let dialCode: String

    var id: String { name }

    static let `default` = all[0]

    static let all: [CountryDialCode] = [
        CountryDialCode(flag: "🇺🇸", name: "United States", dialCode: "+1"),
        CountryDialCode(flag: "🇨🇦", name: "Canada", dialCode: "+1"),
        CountryDialCode(flag: "🇬🇧", name: "United Kingdom", dialCode: "+44"),
        CountryDialCode(flag: "🇦🇺", name: "Australia", dialCode: "+61"),
        CountryDialCode(flag: "🇮🇪", name: "Ireland", dialCode: "+353"),
        CountryDialCode(flag: "🇫🇷", name: "France", dialCode: "+33"),
        CountryDialCode(flag: "🇩🇪", name: "Germany", dialCode: "+49"),
        CountryDialCode(flag: "🇪🇸", name: "Spain", dialCode: "+34"),
        CountryDialCode(flag: "🇮🇹", name: "Italy", dialCode: "+39"),
        CountryDialCode(flag: "🇳🇱", name: "Netherlands", dialCode: "+31"),
        CountryDialCode(flag: "🇧🇷", name: "Brazil", dialCode: "+55"),
        CountryDialCode(flag: "🇲🇽", name: "Mexico", dialCode: "+52"),
        CountryDialCode(flag: "🇮🇳", name: "India", dialCode: "+91"),
        CountryDialCode(flag: "🇯🇵", name: "Japan", dialCode: "+81"),
        CountryDialCode(flag: "🇰🇷", name: "South Korea", dialCode: "+82"),
        CountryDialCode(flag: "🇸🇬", name: "Singapore", dialCode: "+65"),
        CountryDialCode(flag: "🇳🇬", name: "Nigeria", dialCode: "+234"),
        CountryDialCode(flag: "🇿🇦", name: "South Africa", dialCode: "+27")
    ]
}

/// The sign-in state machine: number → SMS → code → session.
///
/// Owned by the welcome screen, not by `SessionStore` — it is multi-step UI
/// state that dies with the screen. Only the outcome touches the session, via
/// the auth service, whose `userStream` then moves routing forward. The
/// verification id lives here and nowhere else, exactly as long as the OTP
/// round trip needs it.
@MainActor
final class PhoneAuthModel: ObservableObject {

    enum Stage: Equatable {
        case enteringNumber
        case sendingCode
        /// SMS is out; the OTP screen is up.
        case codeSent
        case verifying
    }

    @Published var countryCode: CountryDialCode = .default
    /// The national part as typed — digits, spaces, dashes tolerated.
    @Published var nationalNumber: String = ""
    /// The OTP as typed. Capped at `codeLength` digits by the view.
    @Published var code: String = ""
    @Published private(set) var stage: Stage = .enteringNumber
    /// Shown inline by the hosting screen, not as a global alert — a mistyped
    /// code is part of the flow, not an app failure.
    @Published var error: AuthError?
    /// Seconds until another SMS may be requested.
    @Published private(set) var resendCooldown: Int = 0
    /// A resend is in flight. Set synchronously on entry — the cooldown only
    /// starts once the SMS is out, so without this a double-tap (or a tap
    /// during a slow send) fired two SMS and invalidated the first code.
    @Published private(set) var isResending = false

    static let codeLength = 6
    /// Seconds between SMS requests. Injectable so the resend path is testable
    /// without a 30-second wait.
    private let resendInterval: Int

    /// The E.164 number the current SMS went to, for display on the OTP screen.
    private(set) var sentToNumber = ""
    private var verificationID: String?
    private var flowTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?

    private let auth: AuthenticationService

    init(auth: AuthenticationService, resendInterval: Int = 30) {
        self.auth = auth
        self.resendInterval = resendInterval
    }

    deinit {
        flowTask?.cancel()
        cooldownTask?.cancel()
    }

    var isBusy: Bool { stage == .sendingCode || stage == .verifying }

    /// The assembled E.164 number, or nil while the input can't be one.
    var e164Number: String? {
        let digits = nationalNumber.filter(\.isNumber)
        guard (6...14).contains(digits.count) else { return nil }
        return countryCode.dialCode + digits
    }

    // MARK: - Send

    /// Validates consent and the number, then sends the SMS. Consent is
    /// checked here as well as in the UI so a screen that forgets to gate its
    /// button still cannot start an account without it.
    func sendCode(hasConsented: Bool) {
        guard hasConsented else {
            error = .consentRequired
            return
        }
        guard let number = e164Number else {
            error = .invalidPhoneNumber
            return
        }
        guard !isBusy else { return }

        error = nil
        stage = .sendingCode

        flowTask = Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await auth.sendCode(to: number)
                verificationID = id
                sentToNumber = number
                code = ""
                stage = .codeSent
                startResendCooldown()
            } catch let authError as AuthError {
                if authError != .cancelled { error = authError }
                stage = .enteringNumber
            } catch is CancellationError {
                stage = .enteringNumber
            } catch {
                self.error = .smsSendFailed
                stage = .enteringNumber
            }
        }
    }

    /// Another SMS to the same number. Throttled by the cooldown, and
    /// re-entrancy is refused synchronously — one tap, one SMS.
    func resendCode() {
        guard stage == .codeSent, resendCooldown == 0, !isResending,
              !sentToNumber.isEmpty else { return }
        error = nil
        isResending = true

        flowTask = Task { [weak self] in
            guard let self else { return }
            defer { isResending = false }
            do {
                let id = try await auth.sendCode(to: sentToNumber)
                verificationID = id
                code = ""
                startResendCooldown()
            } catch let authError as AuthError {
                if authError != .cancelled { error = authError }
            } catch is CancellationError {
                // Torn down; nothing to report.
            } catch {
                self.error = .smsSendFailed
            }
        }
    }

    // MARK: - Verify

    /// Exchanges the code for a session. Success publishes through
    /// `userStream`; routing moves the app on and this screen is torn down.
    func verifyCode() {
        guard stage == .codeSent else { return }
        guard let verificationID, code.count == Self.codeLength else {
            error = .invalidVerificationCode
            return
        }

        error = nil
        stage = .verifying

        flowTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await auth.signIn(
                    verificationID: verificationID,
                    code: code,
                    consent: .now()
                )
            } catch let authError as AuthError {
                if authError != .cancelled { error = authError }
                if authError == .invalidVerificationCode {
                    // Clear for retyping; the session (and the SMS) are still
                    // good for another attempt.
                    code = ""
                }
                // An expired id needs a fresh SMS; the OTP screen stays up and
                // says so, with resend as the way forward.
                stage = .codeSent
            } catch is CancellationError {
                stage = .codeSent
            } catch {
                self.error = .unknown("Please try again.")
                stage = .codeSent
            }
        }
    }

    // MARK: - Navigation

    /// Back from the OTP screen to the number. The verification id is
    /// deliberately dropped — it belonged to the abandoned SMS.
    func editNumber() {
        flowTask?.cancel()
        verificationID = nil
        code = ""
        error = nil
        stage = .enteringNumber
    }

    /// Abandon whatever is in flight (screen dismissed, app backgrounded).
    func cancel() {
        flowTask?.cancel()
        cooldownTask?.cancel()
        resendCooldown = 0
        isResending = false
    }

    // MARK: - Cooldown

    private func startResendCooldown() {
        cooldownTask?.cancel()
        resendCooldown = resendInterval
        cooldownTask = Task { [weak self] in
            while let self, resendCooldown > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                resendCooldown -= 1
            }
        }
    }
}
