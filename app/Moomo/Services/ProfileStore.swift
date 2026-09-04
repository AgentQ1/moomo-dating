import Foundation

/// Reads and writes the authenticated user's documents.
///
/// A protocol so `FirebaseAuthenticationService` is testable without a live
/// Firestore, and so the mock backend uses the same shape.
protocol ProfileStore: Sendable {
    /// Creates the user's documents if they don't exist and returns the
    /// current `User`.
    ///
    /// **Must be idempotent.** It runs on every sign-in *and* on every auth
    /// state change, which includes each relaunch and every token refresh. If
    /// it were not, a returning user would get duplicate documents or a reset
    /// profile.
    ///
    /// - Parameter consent: Recorded on first creation, or when the accepted
    ///   version is stale. Nil on plain state restoration, which must not
    ///   touch it.
    func bootstrap(uid: String, consent: ConsentRecord?) async throws -> User

    func update(uid: String, profile: Profile) async throws -> User
    func markOnboardingComplete(uid: String) async throws -> User

    /// The user document from the local Firestore cache, for offline launch.
    /// Nil when the store has no cache (the mock, or a cold install).
    func loadCached(uid: String) async -> User?
}

extension ProfileStore {
    func loadCached(uid: String) async -> User? { nil }
}

/// Firestore document layout.
///
///     users/{uid}                      private account data — owner only
///     users/{uid}/private/onboarding   resumable draft
///     users/{uid}/callHistory/{sid}    this user's view of a finished call — server-written
///     users/{uid}/notifications/{id}   bell feed — server-written, owner marks read
///     publicProfiles/{uid}             the projection others may see
///     matchmakingQueue/{uid}           queue entry — server-written, owner reads
///     callInvites/{uid}                incoming call ring — server-written, owner reads
///     callSessions/{id}                live call state — server-owned
///     matches/{pairKey}                mutual likes — server-owned
///     conversations/{id}               one per match — server-owned
///     conversations/{id}/messages/{id} the thread — participants append
///     blocks/{uid}/blocked/{uid}       block list — created by callable, owner reads/deletes
///     boosts/{uid}                     boost entitlement — server-owned, owner reads
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
    /// The coarse position that ranks Discover by distance. Private by
    /// path: rules allow only its owner to read it (CoarseLocationReporter).
    static let locationDocument = "location"
    static let callHistory = "callHistory"
    static let notifications = "notifications"
    static let matchmakingQueue = "matchmakingQueue"
    static let callInvites = "callInvites"
    static let callSessions = "callSessions"
    static let matches = "matches"
    static let conversations = "conversations"
    static let messages = "messages"
    static let blocks = "blocks"
    static let blocked = "blocked"
    static let boosts = "boosts"
}
