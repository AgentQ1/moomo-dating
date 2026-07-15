import XCTest
@testable import Moomo

/// Consent gating, auth failures, cancellation, retry, guest linking, and the
/// returning-user routing rule.
@MainActor
final class AuthenticationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: MockUserStore!
    private var auth: MockAuthenticationService!
    private var session: SessionStore!

    override func setUp() async throws {
        try await super.setUp()
        // Isolated defaults so tests can't see each other's accounts or the
        // simulator's real state.
        let suite = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = MockUserStore(defaults: defaults)
        auth = MockAuthenticationService(latency: .milliseconds(1), store: store)
        session = SessionStore(auth: auth, credentials: MockCredentialProvider())
        await settle()
    }

    override func tearDown() async throws {
        store.reset()
        session = nil
        auth = nil
        store = nil
        defaults = nil
        try await super.tearDown()
    }

    /// Lets the userStream observation task deliver before assertions.
    private func settle(_ ms: UInt64 = 60) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    // MARK: - Consent

    func testSignInWithoutConsentIsRefused() async {
        session.signIn(with: .guest, hasConsented: false)
        await settle()

        XCTAssertEqual(session.error, .consentRequired)
        XCTAssertNil(session.user, "No account may be created without consent")
        XCTAssertEqual(session.route, .welcome)
    }

    func testSignInWithConsentCreatesAccountAndRecordsConsent() async throws {
        session.signIn(with: .guest, hasConsented: true)
        await settle(300)

        XCTAssertNil(session.error)
        let user = try XCTUnwrap(session.user)
        XCTAssertEqual(user.authProvider, .guest)
        XCTAssertEqual(user.consent?.documentVersion, ConsentRecord.currentVersion)
        XCTAssertNotNil(user.consent?.acceptedAt)
    }

    /// Consent must be enforced by the store, not only by disabling buttons.
    func testConsentIsEnforcedBelowTheUILayer() async {
        session.signIn(with: .apple, hasConsented: false)
        await settle()
        XCTAssertNil(auth.currentUser)
    }

    // MARK: - Routing

    func testNewUserRoutesToOnboardingNotMain() async {
        session.signIn(with: .guest, hasConsented: true)
        await settle(300)
        XCTAssertEqual(session.route, .onboarding)
    }

    func testCompletedProfileRoutesToMain() async {
        session.signIn(with: .guest, hasConsented: true)
        await settle(300)

        await session.updateProfile(.completeGuestProfile)
        await session.completeOnboarding()
        await settle(200)

        XCTAssertEqual(session.route, .main)
    }

    /// Onboarding "completed" is not sufficient on its own — a profile that
    /// has lost a required field must go back, not into a broken app.
    func testCompletedOnboardingWithMissingFieldsRoutesToOnboarding() async {
        session.signIn(with: .guest, hasConsented: true)
        await settle(300)

        var broken = Profile.completeGuestProfile
        broken.displayName = ""
        await session.updateProfile(broken)
        await session.completeOnboarding()
        await settle(200)

        XCTAssertEqual(session.route, .onboarding)
    }

    /// A user who agreed to a superseded policy must re-consent.
    func testStaleConsentVersionIsNotValidProfileState() {
        let user = User(
            id: "u1",
            authProvider: .apple,
            consent: ConsentRecord(acceptedAt: Date(), documentVersion: "1999-01-01"),
            profile: .completeGuestProfile,
            createdAt: Date(),
            onboardingCompletedAt: Date()
        )
        XCTAssertFalse(user.hasValidProfileState)
    }

    func testReturningUserKeepsSameAccount() async {
        session.signIn(with: .guest, hasConsented: true)
        await settle(300)
        let firstID = session.user?.id

        session.signOut()
        await settle(500)
        XCTAssertEqual(session.route, .welcome)

        session.signIn(with: .guest, hasConsented: true)
        await settle(300)

        XCTAssertEqual(session.user?.id, firstID, "Signing back in must return the same account")
    }

    // MARK: - Failures

    func testNetworkFailureSurfacesRetryableError() async {
        auth.nextFailure = .network
        session.signIn(with: .guest, hasConsented: true)
        await settle(300)

        XCTAssertEqual(session.error, .network)
        XCTAssertTrue(session.error?.isRetryable ?? false)
        XCTAssertNil(session.user)
    }

    func testRetryAfterFailureSucceeds() async {
        auth.nextFailure = .network
        session.signIn(with: .guest, hasConsented: true)
        await settle(300)
        XCTAssertNotNil(session.error)

        session.retry(provider: .guest)
        await settle(300)

        XCTAssertNil(session.error)
        XCTAssertNotNil(session.user)
    }

    /// Backing out is a choice, not a failure. Showing an alert for it is a bug.
    func testCancellationDoesNotSurfaceAnError() async {
        auth.nextFailure = .cancelled
        session.signIn(with: .guest, hasConsented: true)
        await settle(300)

        XCTAssertNil(session.error, "Cancelling must never raise an alert")
        XCTAssertNil(session.user)
    }

    func testDisabledAccountIsNotRetryable() {
        XCTAssertFalse(AuthError.accountDisabled.isRetryable)
        XCTAssertFalse(AuthError.cancelled.isRetryable)
        XCTAssertTrue(AuthError.network.isRetryable)
    }

    func testConcurrentSignInAttemptsAreIgnored() async {
        session.signIn(with: .guest, hasConsented: true)
        session.signIn(with: .apple, hasConsented: true)
        await settle(400)

        // The second attempt must not have displaced the first.
        XCTAssertEqual(session.user?.authProvider, .guest)
    }

    // MARK: - Guest linking

    func testLinkingGuestKeepsUidAndProfile() async {
        session.signIn(with: .guest, hasConsented: true)
        await settle(300)

        await session.updateProfile(.completeGuestProfile)
        await settle(150)

        let guestID = session.user?.id
        await session.linkGuestAccount(with: .apple)
        await settle(300)

        XCTAssertEqual(session.user?.id, guestID, "Linking must keep the same uid")
        XCTAssertEqual(session.user?.authProvider, .apple)
        XCTAssertEqual(session.user?.profile.displayName, Profile.completeGuestProfile.displayName)
        XCTAssertFalse(session.user?.isGuest ?? true)
    }

    func testLinkingToAnAlreadyUsedProviderFails() async {
        // An Apple account already exists.
        session.signIn(with: .apple, hasConsented: true)
        await settle(300)
        session.signOut()
        await settle(500)

        session.signIn(with: .guest, hasConsented: true)
        await settle(300)

        await session.linkGuestAccount(with: .apple)
        await settle(300)

        XCTAssertEqual(session.error, .credentialAlreadyInUse)
        XCTAssertTrue(session.user?.isGuest ?? false, "Failed link must leave the guest intact")
    }
}

extension Profile {
    /// Satisfies the guest requirements: name, age, gender, interested-in.
    static var completeGuestProfile: Profile {
        var profile = Profile()
        profile.displayName = "Sam"
        profile.dateOfBirth = Calendar.current.date(byAdding: .year, value: -24, to: Date())
        profile.gender = .nonBinary
        profile.interestedIn = [.everyone]
        return profile
    }

    /// Satisfies the full requirements, including location and photos.
    static var completeFullProfile: Profile {
        var profile = completeGuestProfile
        profile.location = CityLocation(city: "New York", region: "NY", countryCode: "US")
        profile.photos = [ProfilePhoto(id: "p1", remotePath: nil, order: 0)]
        profile.bio = "Coffee and terrible puns."
        profile.interests = ["Coffee", "Films", "Hiking"]
        return profile
    }
}
