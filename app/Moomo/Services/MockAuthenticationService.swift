import Foundation

/// In-memory authentication, used until a real Firebase project is configured.
///
/// This is **not** a fake-success stub. It runs the same state machine the
/// Firebase implementation will: real async work, real latency, real
/// cancellation, real failures, and persistence across relaunches (via
/// `UserDefaults` rather than a server). Onboarding resume, guest linking, and
/// returning-user routing therefore behave identically in both modes, which is
/// the point — bugs in those flows surface here rather than after the backend
/// lands.
///
/// It is labeled in the UI by `MockModeBanner` and can never be reached when a
/// real config is present.
final class MockAuthenticationService: AuthenticationService, @unchecked Sendable {

    /// Simulated round trip. Long enough that loading states are real and
    /// visible, short enough not to be irritating.
    private let latency: Duration

    /// Injects a failure on the next call. Used by tests and by the debug menu
    /// to exercise error and retry paths.
    var nextFailure: AuthError?

    private let store: MockUserStore
    private let lock = NSLock()
    private var _currentUser: User?
    private var continuations: [UUID: AsyncStream<User?>.Continuation] = [:]

    init(latency: Duration = .milliseconds(700), store: MockUserStore = .standard) {
        self.latency = latency
        self.store = store
        self._currentUser = store.loadPersistedUser()
    }

    var currentUser: User? {
        lock.lock(); defer { lock.unlock() }
        return _currentUser
    }

    var userStream: AsyncStream<User?> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let user = _currentUser
            lock.unlock()

            continuation.yield(user)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock()
                continuations[id] = nil
                lock.unlock()
            }
        }
    }

    // MARK: - Sign in

    func signIn(with credential: ProviderCredential, consent: ConsentRecord) async throws -> User {
        try await simulateRoundTrip()

        let provider: AuthProvider
        var name = ""

        switch credential {
        case .apple(_, _, let fullName, _):
            provider = .apple
            name = fullName ?? ""
        case .google:
            provider = .google
        case .anonymous:
            provider = .guest
        }

        // Returning user: same provider identity keeps its uid and everything
        // built under it, including partially-finished onboarding.
        if let existing = store.loadUser(forProvider: provider) {
            var user = existing
            // Re-record consent if the policy moved on since they last agreed.
            if user.consent?.isCurrent != true {
                user.consent = consent
            }
            persist(user)
            return user
        }

        var profile = Profile()
        profile.displayName = name

        let user = User(
            id: "mock-\(provider.rawValue)-\(UUID().uuidString.prefix(8))",
            authProvider: provider,
            consent: consent,
            profile: profile,
            createdAt: Date(),
            onboardingCompletedAt: nil
        )
        persist(user)
        return user
    }

    // MARK: - Linking

    func linkGuestAccount(with credential: ProviderCredential) async throws -> User {
        try await simulateRoundTrip()

        guard var user = currentUser else {
            throw AuthError.unknown("Not signed in.")
        }
        guard user.isGuest else {
            throw AuthError.unknown("Only guest accounts can be linked.")
        }

        let provider: AuthProvider
        switch credential {
        case .apple: provider = .apple
        case .google: provider = .google
        case .anonymous: throw AuthError.unknown("Cannot link a guest to a guest.")
        }

        // A provider identity may back only one account.
        if store.loadUser(forProvider: provider) != nil {
            throw AuthError.credentialAlreadyInUse
        }

        // Upgrade in place: same uid, same profile, same onboarding progress.
        store.removeUser(forProvider: .guest)
        user.authProvider = provider
        persist(user)
        return user
    }

    // MARK: - Profile

    func updateProfile(_ profile: Profile) async throws {
        try await Task.sleep(for: .milliseconds(120))
        guard var user = currentUser else { throw AuthError.unknown("Not signed in.") }
        user.profile = profile
        persist(user)
    }

    func completeOnboarding() async throws {
        try await simulateRoundTrip()
        guard var user = currentUser else { throw AuthError.unknown("Not signed in.") }
        user.onboardingCompletedAt = Date()
        persist(user)
    }

    func signOut() async throws {
        try await Task.sleep(for: .milliseconds(200))
        lock.lock()
        _currentUser = nil
        let targets = Array(continuations.values)
        lock.unlock()

        store.clearSession()
        targets.forEach { $0.yield(nil) }
    }

    // MARK: - Internals

    /// Latency plus injected failure, with real cooperative cancellation —
    /// backing out of a sign-in mid-flight must actually stop it.
    private func simulateRoundTrip() async throws {
        do {
            try await Task.sleep(for: latency)
        } catch is CancellationError {
            throw AuthError.cancelled
        }
        try Task.checkCancellation()

        if let failure = nextFailure {
            nextFailure = nil
            throw failure
        }
    }

    private func persist(_ user: User) {
        lock.lock()
        _currentUser = user
        let targets = Array(continuations.values)
        lock.unlock()

        store.save(user)
        targets.forEach { $0.yield(user) }
    }
}

/// Disk-backed storage for the mock backend, so onboarding survives relaunch
/// exactly as it will against a real server.
final class MockUserStore: @unchecked Sendable {
    static let standard = MockUserStore(defaults: .standard)

    private let defaults: UserDefaults
    private let sessionKey = "mock.session.provider"
    private let userKeyPrefix = "mock.user."

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func save(_ user: User) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        defaults.set(data, forKey: userKeyPrefix + user.authProvider.rawValue)
        defaults.set(user.authProvider.rawValue, forKey: sessionKey)
    }

    func loadUser(forProvider provider: AuthProvider) -> User? {
        guard let data = defaults.data(forKey: userKeyPrefix + provider.rawValue) else {
            return nil
        }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    func loadPersistedUser() -> User? {
        guard
            let raw = defaults.string(forKey: sessionKey),
            let provider = AuthProvider(rawValue: raw)
        else { return nil }
        return loadUser(forProvider: provider)
    }

    func removeUser(forProvider provider: AuthProvider) {
        defaults.removeObject(forKey: userKeyPrefix + provider.rawValue)
    }

    /// Ends the session but keeps accounts, so signing back in returns the
    /// same user — matching real backend behaviour.
    func clearSession() {
        defaults.removeObject(forKey: sessionKey)
    }

    /// Wipes everything. Tests and the debug menu only.
    func reset() {
        for provider in AuthProvider.allCases {
            defaults.removeObject(forKey: userKeyPrefix + provider.rawValue)
        }
        defaults.removeObject(forKey: sessionKey)
    }
}
