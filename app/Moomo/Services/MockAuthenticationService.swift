import Foundation

/// In-memory authentication, used until a real Firebase project is configured.
///
/// This is **not** a fake-success stub. It runs the same state machine the
/// Firebase implementation does: real async work, real latency, real
/// cancellation, real failures, and persistence across relaunches (via
/// `UserDefaults` rather than a server). The phone OTP flow, onboarding
/// resume, and returning-user routing therefore behave identically in both
/// modes, which is the point — bugs in those flows surface here rather than
/// after the backend lands.
///
/// It is labeled in the UI by `MockModeBanner` and can never be reached when a
/// real config is present.
final class MockAuthenticationService: AuthenticationService, @unchecked Sendable {

    /// The only SMS code the mock accepts. Fixed so UI tests can type it.
    static let validVerificationCode = "123456"

    /// The verification id "sent" by the mock SMS round trip.
    static let mockVerificationID = "mock-verification-id"

    /// Simulated round trip. Long enough that loading states are real and
    /// visible, short enough not to be irritating.
    private let latency: Duration

    /// Injects a failure on the next call. Used by tests and by the debug menu
    /// to exercise error and retry paths.
    var nextFailure: AuthError?

    private let store: MockUserStore
    private let lock = NSLock()
    private var _currentUser: User?
    /// The number the last verification SMS was "sent" to, so verifying the
    /// code knows which number it proves ownership of.
    private var pendingPhoneNumber: String?
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

    // MARK: - Phone OTP

    func sendCode(to phoneNumber: String) async throws -> String {
        try await simulateRoundTrip()

        // The same rough shape check a backend would run before sending.
        let digits = phoneNumber.filter(\.isNumber)
        guard phoneNumber.hasPrefix("+"), digits.count >= 8, digits.count <= 15 else {
            throw AuthError.invalidPhoneNumber
        }

        lock.withLock { pendingPhoneNumber = phoneNumber }
        return Self.mockVerificationID
    }

    /// The phone number is the identity: the same number always signs into the
    /// same stored account, a new number creates one — mirroring how Firebase
    /// resolves a verified number to its uid.
    func signIn(verificationID: String, code: String, consent: ConsentRecord) async throws -> User {
        try await simulateRoundTrip()

        let phoneNumber = try consumeVerifiedPhone(verificationID: verificationID, code: code)

        // Returning user: same number keeps its uid and everything built under
        // it, including partially-finished onboarding.
        if var user = store.loadUser(forPhone: phoneNumber) {
            // Re-record consent if the policy moved on since they last agreed.
            if user.consent?.isCurrent != true {
                user.consent = consent
            }
            persist(user)
            return user
        }

        let user = User(
            id: "mock-phone-\(UUID().uuidString.prefix(8))",
            authProvider: .phone,
            consent: consent,
            profile: Profile(),
            createdAt: Date(),
            onboardingCompletedAt: nil,
            phoneNumber: phoneNumber
        )
        persist(user)
        return user
    }

    /// Checks the code against the pending SMS and hands back the proven
    /// number. Single-use, like a real verification session.
    private func consumeVerifiedPhone(verificationID: String, code: String) throws -> String {
        lock.lock()
        let pending = pendingPhoneNumber
        lock.unlock()

        guard verificationID == Self.mockVerificationID, let pending else {
            throw AuthError.verificationExpired
        }
        guard code == Self.validVerificationCode else {
            throw AuthError.invalidVerificationCode
        }

        lock.lock()
        pendingPhoneNumber = nil
        lock.unlock()
        return pending
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
        let targets = lock.withLock {
            _currentUser = nil
            return Array(continuations.values)
        }

        store.clearSession()
        targets.forEach { $0.yield(nil) }
    }

    // MARK: - Account deletion

    /// Mirrors the real service: the account and its data are gone for good,
    /// unlike sign-out, which keeps the stored user for the next sign-in.
    func deleteAccount() async throws {
        try await simulateRoundTrip()

        let (user, targets) = lock.withLock {
            let user = _currentUser
            _currentUser = nil
            return (user, Array(continuations.values))
        }

        guard let user else { throw AuthError.unknown("Not signed in.") }
        if let phoneNumber = user.phoneNumber {
            store.removeUser(forPhone: phoneNumber)
        }
        store.clearSession()
        OnboardingDraftStorage.standard.clear(for: user.id)
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
/// exactly as it will against a real server. Accounts are keyed by verified
/// phone number — the same identity rule the real backend applies.
final class MockUserStore: @unchecked Sendable {
    static let standard = MockUserStore(defaults: .standard)

    private let defaults: UserDefaults
    private let sessionKey = "mock.session.phone"
    private let userKeyPrefix = "mock.user.phone."

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func save(_ user: User) {
        guard let phoneNumber = user.phoneNumber,
              let data = try? JSONEncoder().encode(user) else { return }
        defaults.set(data, forKey: userKeyPrefix + phoneNumber)
        defaults.set(phoneNumber, forKey: sessionKey)
    }

    func loadUser(forPhone phoneNumber: String) -> User? {
        guard let data = defaults.data(forKey: userKeyPrefix + phoneNumber) else {
            return nil
        }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    func loadPersistedUser() -> User? {
        guard let phoneNumber = defaults.string(forKey: sessionKey) else { return nil }
        return loadUser(forPhone: phoneNumber)
    }

    func removeUser(forPhone phoneNumber: String) {
        defaults.removeObject(forKey: userKeyPrefix + phoneNumber)
    }

    /// Ends the session but keeps accounts, so signing back in returns the
    /// same user — matching real backend behaviour.
    func clearSession() {
        defaults.removeObject(forKey: sessionKey)
    }

    /// Wipes everything. Tests and the debug menu only.
    func reset() {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(userKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: sessionKey)
    }
}
