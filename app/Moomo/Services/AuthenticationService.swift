import Foundation

/// Errors surfaced to the user during sign-in.
enum AuthError: LocalizedError, Equatable {
    /// The user backed out. Not an error condition — must never show an alert.
    case cancelled
    case network
    case consentRequired
    case providerFailed(String)
    case accountDisabled
    /// Guest tried to link to a provider already attached to another account.
    case credentialAlreadyInUse
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            nil
        case .network:
            "No connection. Check your network and try again."
        case .consentRequired:
            "Please agree to the Privacy Policy and Terms of Service first."
        case .providerFailed(let name):
            "\(name) sign-in didn't complete. Please try again."
        case .accountDisabled:
            "This account has been disabled. Contact support@moomo.app."
        case .credentialAlreadyInUse:
            "That account is already linked to another Moomo profile. Sign in with it directly."
        case .unknown(let detail):
            "Something went wrong. \(detail)"
        }
    }

    /// Whether offering "Try again" makes sense. Retrying a cancellation or a
    /// disabled account is pointless.
    var isRetryable: Bool {
        switch self {
        case .network, .providerFailed, .unknown: true
        case .cancelled, .consentRequired, .accountDisabled, .credentialAlreadyInUse: false
        }
    }
}

/// A credential obtained from a provider, ready to be exchanged for a session.
///
/// Split from the backend deliberately: Apple's credential comes from
/// `AuthenticationServices` and is real regardless of which backend consumes
/// it, so the native flow works identically in mock and Firebase mode.
enum ProviderCredential: Equatable {
    case apple(idToken: String, nonce: String, fullName: String?, email: String?)
    case google(idToken: String, accessToken: String)
    case anonymous
}

/// The authentication contract. Swapped between mock and Firebase at the
/// composition root; nothing above this line knows which is in play.
protocol AuthenticationService: AnyObject, Sendable {
    /// The current account, or nil when signed out. Emits on every change.
    var userStream: AsyncStream<User?> { get }

    /// Last known user, synchronously. Nil when signed out.
    var currentUser: User? { get }

    /// Exchange a provider credential for a session, creating the account if
    /// needed. `consent` is persisted with the account on creation.
    func signIn(with credential: ProviderCredential, consent: ConsentRecord) async throws -> User

    /// Attach a real provider to the signed-in guest account, keeping its uid
    /// and everything built under it.
    func linkGuestAccount(with credential: ProviderCredential) async throws -> User

    /// Persist profile changes for the signed-in user.
    func updateProfile(_ profile: Profile) async throws

    /// Mark onboarding finished.
    func completeOnboarding() async throws

    func signOut() async throws
}
