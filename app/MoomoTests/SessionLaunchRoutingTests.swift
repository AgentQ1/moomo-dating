import XCTest
import Combine
@testable import Moomo

/// Launch routing while the auth backend has not yet resolved the persisted
/// session.
///
/// Regression: `FirebaseAuthenticationService.userStream` used to replay its
/// current value — nil until Firebase's state listener fired — to every new
/// subscriber. `SessionStore` maps nil to `.welcome`, so every returning user
/// flashed the welcome screen for a frame before landing on main. The stream
/// now stays silent until the backend has either confirmed signed-out or
/// restored the real user; these tests pin the store's side of that contract
/// against a backend frozen mid-restore.
@MainActor
final class SessionLaunchRoutingTests: XCTestCase {

    private var auth: UnresolvedAuthService!
    private var session: SessionStore!

    override func setUp() async throws {
        try await super.setUp()
        auth = UnresolvedAuthService()
        session = SessionStore(auth: auth)
    }

    override func tearDown() async throws {
        session = nil
        auth = nil
        try await super.tearDown()
    }

    /// Lets the userStream observation task deliver before assertions.
    private func settle(_ ms: UInt64 = 60) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// While restore is pending — network retries included — the app must sit
    /// on the launch screen, not welcome.
    func testRouteStaysOnLaunchingWhileRestoreIsUnresolved() async {
        await settle(200)

        XCTAssertEqual(session.route, .launching)
        XCTAssertNil(session.user)
    }

    /// A returning user with a completed profile lands on main without the
    /// route ever passing through `.welcome`.
    func testRestoredUserLandsOnMainWithoutTouchingWelcome() async {
        var seen: [SessionStore.Route] = []
        let observation = session.$route.sink { seen.append($0) }
        defer { observation.cancel() }

        await settle()
        auth.emit(.restoredCompletedUser)
        await settle()

        XCTAssertEqual(session.route, .main)
        XCTAssertFalse(seen.contains(.welcome), "A returning user must never glimpse welcome")
    }

    /// Nil is only ever emitted once signed-out is *confirmed* — and then
    /// welcome is correct.
    func testConfirmedSignedOutRoutesToWelcome() async {
        await settle()
        XCTAssertEqual(session.route, .launching)

        auth.emit(nil)
        await settle()

        XCTAssertEqual(session.route, .welcome)
    }
}

private extension User {
    /// A fully onboarded returning user, as a successful restore publishes.
    static var restoredCompletedUser: User {
        User(
            id: "restored-1",
            authProvider: .phone,
            consent: .now(),
            profile: .completeFullProfile,
            createdAt: Date(),
            onboardingCompletedAt: Date(),
            phoneNumber: "+15550100200"
        )
    }
}

/// An auth backend frozen mid-restore: like the fixed Firebase service, it
/// emits nothing until the session is resolved by `emit`.
private final class UnresolvedAuthService: AuthenticationService, @unchecked Sendable {

    private let lock = NSLock()
    private var _currentUser: User?
    private var continuations: [UUID: AsyncStream<User?>.Continuation] = [:]

    var currentUser: User? {
        lock.lock(); defer { lock.unlock() }
        return _currentUser
    }

    var userStream: AsyncStream<User?> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock()
                continuations[id] = nil
                lock.unlock()
            }
        }
    }

    /// Resolves the session: a user for a successful restore, nil for
    /// confirmed signed-out.
    func emit(_ user: User?) {
        lock.lock()
        _currentUser = user
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(user) }
    }

    // Unused by these tests.

    func sendCode(to phoneNumber: String) async throws -> String {
        throw AuthError.unknown("Unused in launch routing tests.")
    }

    func signIn(verificationID: String, code: String, consent: ConsentRecord) async throws -> User {
        throw AuthError.unknown("Unused in launch routing tests.")
    }

    func updateProfile(_ profile: Profile) async throws {
        throw AuthError.unknown("Unused in launch routing tests.")
    }

    func completeOnboarding() async throws {
        throw AuthError.unknown("Unused in launch routing tests.")
    }

    func signOut() async throws {}

    func deleteAccount() async throws {
        throw AuthError.unknown("Unused in launch routing tests.")
    }
}
