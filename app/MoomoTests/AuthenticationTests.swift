import XCTest
@testable import Moomo

/// The phone OTP flow: consent gating, sending and verifying codes, failures,
/// cancellation, and the returning-user routing rule.
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
        session = SessionStore(auth: auth)
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

    /// Drives the whole mock phone flow: send SMS, type the valid code, sign
    /// in.
    @discardableResult
    private func completePhoneFlow(
        number: String = "5550100200"
    ) async -> PhoneAuthModel {
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = number
        model.sendCode(hasConsented: true)
        await settle(150)
        model.code = MockAuthenticationService.validVerificationCode
        model.verifyCode()
        await settle(300)
        return model
    }

    // MARK: - Consent

    func testSendCodeWithoutConsentIsRefused() async {
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: false)
        await settle()

        XCTAssertEqual(model.error, .consentRequired)
        XCTAssertEqual(model.stage, .enteringNumber, "No SMS may go out without consent")
        XCTAssertNil(session.user)
    }

    // MARK: - Sign in

    func testPhoneSignInCreatesAccountAndRecordsConsent() async throws {
        await completePhoneFlow()

        let user = try XCTUnwrap(session.user)
        XCTAssertEqual(user.authProvider, .phone)
        XCTAssertEqual(user.phoneNumber, "+15550100200")
        XCTAssertEqual(user.consent?.documentVersion, ConsentRecord.currentVersion)
        XCTAssertEqual(session.route, .onboarding, "A fresh account goes straight to onboarding")
    }

    func testWrongCodeIsRefusedAndClearedForRetyping() async {
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: true)
        await settle(150)

        model.code = "000000"
        model.verifyCode()
        await settle(300)

        XCTAssertEqual(model.error, .invalidVerificationCode)
        XCTAssertEqual(model.stage, .codeSent, "A wrong code keeps the OTP screen up")
        XCTAssertEqual(model.code, "", "The wrong code is cleared for retyping")
        XCTAssertNil(session.user, "A wrong code must never create an account")
    }

    func testRightCodeAfterWrongCodeRecoversTheFlow() async throws {
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: true)
        await settle(150)

        model.code = "000000"
        model.verifyCode()
        await settle(300)
        XCTAssertNil(session.user)

        model.code = MockAuthenticationService.validVerificationCode
        model.verifyCode()
        await settle(300)

        XCTAssertNil(model.error)
        XCTAssertNotNil(session.user, "The correct code must still work after a wrong one")
    }

    func testMalformedNumberNeverSendsAnSMS() async {
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "12"
        model.sendCode(hasConsented: true)
        await settle(150)

        XCTAssertEqual(model.error, .invalidPhoneNumber)
        XCTAssertEqual(model.stage, .enteringNumber)
    }

    /// A verification session is single-use: once consumed (or never created),
    /// signing in with it reports expiry, and only a fresh SMS continues.
    func testVerificationSessionIsSingleUse() async throws {
        _ = try await auth.sendCode(to: "+15550100200")
        _ = try await auth.signIn(
            verificationID: MockAuthenticationService.mockVerificationID,
            code: MockAuthenticationService.validVerificationCode,
            consent: .now()
        )

        do {
            _ = try await auth.signIn(
                verificationID: MockAuthenticationService.mockVerificationID,
                code: MockAuthenticationService.validVerificationCode,
                consent: .now()
            )
            XCTFail("A consumed verification session must not sign in twice")
        } catch let error as AuthError {
            XCTAssertEqual(error, .verificationExpired)
        }
    }

    // MARK: - Routing

    func testNewUserRoutesToOnboardingNotMain() async {
        await completePhoneFlow()
        XCTAssertEqual(session.route, .onboarding)
    }

    func testCompletedProfileRoutesToMain() async {
        await completePhoneFlow()

        await session.updateProfile(.completeFullProfile)
        await session.completeOnboarding()
        await settle(200)

        XCTAssertEqual(session.route, .main)
    }

    /// Onboarding "completed" is not sufficient on its own — a profile that
    /// has lost a required field must go back, not into a broken app.
    func testCompletedOnboardingWithMissingFieldsRoutesToOnboarding() async {
        await completePhoneFlow()

        var broken = Profile.completeFullProfile
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
            authProvider: .phone,
            consent: ConsentRecord(acceptedAt: Date(), documentVersion: "1999-01-01"),
            profile: .completeFullProfile,
            createdAt: Date(),
            onboardingCompletedAt: Date(),
            phoneNumber: "+15550100200"
        )
        XCTAssertFalse(user.hasValidProfileState)
    }

    // MARK: - Consent-less accounts must not soft-lock

    /// Regression. An account whose document was created without consent — which
    /// the auth-state listener does on every restored session, because it has no
    /// consent to record and must not invent one — used to route to
    /// `.onboarding`. Onboarding has no consent step, so the user could complete
    /// every field, tap "Start meeting people", write it all to Firestore, and
    /// watch the screen not change, forever, with no error.
    ///
    /// It must route to `.welcome`, which is the only place consent is given.
    func testMissingConsentRoutesToWelcomeNotOnboarding() {
        let user = User(
            id: "u1",
            authProvider: .phone,
            consent: nil,
            profile: .completeFullProfile,
            createdAt: Date(),
            onboardingCompletedAt: Date(),
            phoneNumber: "+15550100200"
        )
        XCTAssertFalse(user.hasRecordedCurrentConsent)
        XCTAssertFalse(
            user.hasValidProfileState,
            "No consent means the app is not enterable, however complete the profile is"
        )
    }

    /// The same dead end, reached through the stale-policy door rather than the
    /// missing-consent one.
    func testStaleConsentIsNotTreatedAsRecordedConsent() {
        let user = User(
            id: "u1",
            authProvider: .phone,
            consent: ConsentRecord(acceptedAt: Date(), documentVersion: "1999-01-01"),
            profile: .completeFullProfile,
            createdAt: Date(),
            onboardingCompletedAt: Date(),
            phoneNumber: "+15550100200"
        )
        XCTAssertFalse(user.hasRecordedCurrentConsent)
    }

    /// Current consent is what distinguishes the two.
    func testCurrentConsentIsRecordedConsent() {
        let user = User(
            id: "u1",
            authProvider: .phone,
            consent: .now(),
            profile: .completeFullProfile,
            createdAt: Date(),
            onboardingCompletedAt: Date(),
            phoneNumber: "+15550100200"
        )
        XCTAssertTrue(user.hasRecordedCurrentConsent)
        XCTAssertTrue(user.hasValidProfileState)
    }

    // MARK: - Returning users

    func testReturningUserKeepsSameAccount() async {
        await completePhoneFlow()
        let firstID = session.user?.id

        session.signOut()
        await settle(500)
        XCTAssertEqual(session.route, .welcome)

        await completePhoneFlow()

        XCTAssertEqual(session.user?.id, firstID, "The same number must return the same account")
    }

    func testDifferentNumberGetsADifferentAccount() async {
        await completePhoneFlow(number: "5550100200")
        let firstID = session.user?.id
        session.signOut()
        await settle(500)

        await completePhoneFlow(number: "5559998877")

        XCTAssertNotEqual(session.user?.id, firstID, "Each number owns its own account")
    }

    func testReturningUserResumesPartialOnboarding() async {
        await completePhoneFlow()
        await session.updateProfile(.identityOnlyProfile)
        await settle(150)

        session.signOut()
        await settle(500)
        await completePhoneFlow()

        XCTAssertEqual(
            session.user?.profile.displayName,
            Profile.identityOnlyProfile.displayName,
            "A half-finished profile must survive sign-out and sign-in"
        )
        XCTAssertEqual(session.route, .onboarding)
    }

    // MARK: - Failures

    func testNetworkFailureWhileSendingSMSStaysOnTheNumber() async {
        auth.nextFailure = .network
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: true)
        await settle(150)

        XCTAssertEqual(model.error, .network)
        XCTAssertEqual(model.stage, .enteringNumber, "A failed send returns to the number entry")
    }

    func testFailedSMSSendSurfacesTheError() async {
        auth.nextFailure = .smsSendFailed
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: true)
        await settle(150)

        XCTAssertEqual(model.error, .smsSendFailed)
        XCTAssertEqual(model.stage, .enteringNumber)
        XCTAssertNil(session.user)
    }

    func testTooManyAttemptsSurfacesInline() async {
        auth.nextFailure = .tooManyAttempts
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: true)
        await settle(150)

        XCTAssertEqual(model.error, .tooManyAttempts)
        XCTAssertEqual(model.stage, .enteringNumber)
    }

    func testExpiredVerificationKeepsOTPScreenForResend() async {
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: true)
        await settle(150)

        auth.nextFailure = .verificationExpired
        model.code = MockAuthenticationService.validVerificationCode
        model.verifyCode()
        await settle(300)

        XCTAssertEqual(model.error, .verificationExpired)
        XCTAssertEqual(model.stage, .codeSent, "Expiry stays on the OTP screen; resend is the way forward")
        XCTAssertNil(session.user)
    }

    /// Backing out is a choice, not a failure. Showing an alert for it is a bug.
    func testCancellationDoesNotSurfaceAnError() async {
        auth.nextFailure = .cancelled
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: true)
        await settle(150)

        XCTAssertNil(model.error, "Cancelling must never raise an alert")
        XCTAssertNil(session.user)
    }

    func testBackFromOTPDropsTheVerification() async {
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: true)
        await settle(150)
        XCTAssertEqual(model.stage, .codeSent)

        model.editNumber()

        XCTAssertEqual(model.stage, .enteringNumber)
        XCTAssertEqual(model.code, "")

        // The dropped id must not verify: typing a code without a fresh send
        // is refused before any backend call.
        model.code = MockAuthenticationService.validVerificationCode
        model.verifyCode()
        await settle(300)
        XCTAssertNil(session.user, "An abandoned verification must not sign in")
    }

    // MARK: - Account deletion

    func testDeleteAccountSignsOutAndDestroysTheAccount() async {
        await completePhoneFlow()
        await session.updateProfile(.completeFullProfile)
        await settle(150)
        let deletedID = session.user?.id

        await session.deleteAccount()
        await settle(300)

        XCTAssertNil(session.error)
        XCTAssertNil(session.user, "Deletion must end the session")
        XCTAssertEqual(session.route, .welcome)

        // Unlike sign-out, the account must be gone: signing in again creates
        // a fresh profile rather than restoring the deleted one.
        await completePhoneFlow()
        XCTAssertNotEqual(session.user?.id, deletedID, "Deletion must not be a sign-out")
        XCTAssertEqual(session.user?.profile.displayName, "", "The old profile must not come back")
    }

    func testDeleteAccountFailureKeepsTheSession() async {
        await completePhoneFlow()

        auth.nextFailure = .network
        await session.deleteAccount()
        await settle(200)

        XCTAssertEqual(session.error, .network)
        XCTAssertNotNil(session.user, "A failed deletion must leave the session intact")
    }
}

extension Profile {
    /// Satisfies the basic identity requirements: name, age, gender,
    /// interested-in. Not enough for a full account — no location or photos.
    static var identityOnlyProfile: Profile {
        var profile = Profile()
        profile.displayName = "Sam"
        profile.dateOfBirth = Calendar.current.date(byAdding: .year, value: -24, to: Date())
        profile.gender = .nonBinary
        profile.interestedIn = [.everyone]
        return profile
    }

    /// Satisfies the full requirements, including location and photos.
    static var completeFullProfile: Profile {
        var profile = identityOnlyProfile
        profile.location = CityLocation(city: "New York", region: "NY", countryCode: "US")
        profile.photos = [
            ProfilePhoto(
                id: "p1",
                remotePath: StoragePath.photo(uid: "test-uid", photoId: "p1"),
                order: 0
            )
        ]
        profile.bio = "Coffee and terrible puns."
        profile.interests = ["Coffee", "Films", "Hiking"]
        return profile
    }
}
