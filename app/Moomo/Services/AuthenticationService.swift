import Foundation

/// Errors surfaced to the user during phone sign-in.
enum AuthError: LocalizedError, Equatable {
    /// The user backed out. Not an error condition — must never show an alert.
    case cancelled
    case network
    case consentRequired
    case accountDisabled
    /// The phone number failed validation before or at the backend.
    case invalidPhoneNumber
    /// The SMS could not be sent. Distinct from `.network`: the connection was
    /// fine, the send itself failed.
    case smsSendFailed
    /// The SMS code didn't match. The user retypes it.
    case invalidVerificationCode
    /// The verification session lapsed; only a fresh SMS can continue.
    case verificationExpired
    /// SMS throttling — the backend refuses further attempts for a while.
    case tooManyAttempts
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            nil
        case .network:
            "No connection. Check your network and try again."
        case .consentRequired:
            "Please agree to the Privacy Policy and Terms of Service first."
        case .accountDisabled:
            "This account has been disabled. Contact moomolab@gmail.com."
        case .invalidPhoneNumber:
            "That phone number doesn't look right. Check it and try again."
        case .smsSendFailed:
            "We couldn't send the code. Please try again."
        case .invalidVerificationCode:
            "That code isn't correct. Check the SMS and try again."
        case .verificationExpired:
            "That code has expired. Request a new one."
        case .tooManyAttempts:
            "Too many attempts. Please wait a few minutes and try again."
        case .unknown(let detail):
            "Something went wrong. \(detail)"
        }
    }
}

/// The authentication contract. Phone OTP is the only sign-in method: enter a
/// number, receive an SMS code, exchange it for a session. Swapped between
/// mock and Firebase at the composition root; nothing above this line knows
/// which is in play.
protocol AuthenticationService: AnyObject, Sendable {
    /// The current account, or nil when signed out. Emits on every change.
    var userStream: AsyncStream<User?> { get }

    /// Last known user, synchronously. Nil when signed out.
    var currentUser: User? { get }

    /// Sends the OTP SMS to an E.164 number. Returns the verification id the
    /// OTP entry screen must hold onto — it is the only state the flow
    /// persists, and it dies with the flow.
    func sendCode(to phoneNumber: String) async throws -> String

    /// Exchanges the OTP for a session. The same phone number always resolves
    /// to the same account: an existing user signs back in, a new number
    /// creates the account. `consent` is persisted with the account on
    /// creation (and refreshed if the accepted policy version is stale).
    func signIn(verificationID: String, code: String, consent: ConsentRecord) async throws -> User

    /// Persist profile changes for the signed-in user.
    func updateProfile(_ profile: Profile) async throws

    /// Mark onboarding finished.
    func completeOnboarding() async throws

    func signOut() async throws

    /// Permanently deletes the signed-in account: photos, profile documents,
    /// and the auth user itself. Irreversible. Publishes signed-out state on
    /// success.
    func deleteAccount() async throws
}
