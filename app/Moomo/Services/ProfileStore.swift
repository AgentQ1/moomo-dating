import Foundation

/// Reads and writes the authenticated user's documents.
///
/// A protocol so `FirebaseAuthenticationService` is testable without a live
/// Firestore, and so the mock backend uses the same shape.
protocol ProfileStore: Sendable {
    /// Creates the user's documents if they don't exist, updates provider
    /// metadata if they do, and returns the current `User`.
    ///
    /// **Must be idempotent.** It runs on every sign-in *and* on every auth
    /// state change, which includes each relaunch and every token refresh. If
    /// it were not, a returning user would get duplicate documents or a reset
    /// profile.
    ///
    /// - Parameters:
    ///   - providerDisplayName: A name from the provider, used **only** to fill
    ///     a blank. Apple supplies it once and never again, so it must be
    ///     captured on first sight — but it must never overwrite a name the
    ///     user has since chosen.
    ///   - consent: Recorded on first creation, or when the accepted version is
    ///     stale. Nil on plain state restoration, which must not touch it.
    func bootstrap(
        uid: String,
        provider: AuthProvider,
        providerDisplayName: String?,
        consent: ConsentRecord?
    ) async throws -> User

    func update(uid: String, profile: Profile) async throws -> User
    func markOnboardingComplete(uid: String) async throws -> User
}

/// Firestore document layout.
///
///     users/{uid}                      private account data — owner only
///     users/{uid}/private/onboarding   resumable draft
///     publicProfiles/{uid}             the projection others may see
///
/// The split is the point: `users/{uid}` holds date of birth and consent, which
/// must never be readable by another user. `publicProfiles/{uid}` holds only
/// what Discover shows. Keeping them in one document would make "readable by
/// others" and "contains date of birth" the same decision.
enum FirestorePath {
    static let users = "users"
    static let publicProfiles = "publicProfiles"
    static let privateCollection = "private"
    static let onboardingDocument = "onboarding"
}
