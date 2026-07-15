import XCTest
@testable import Moomo

/// Onboarding validation, resume-after-relaunch, guest flow, and completion.
@MainActor
final class OnboardingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var storage: OnboardingDraftStorage!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        storage = OnboardingDraftStorage(defaults: defaults)
    }

    private func makeUser(guest: Bool = false, id: String = "u1") -> User {
        User(
            id: id,
            authProvider: guest ? .guest : .apple,
            consent: .now(),
            profile: Profile(),
            createdAt: Date(),
            onboardingCompletedAt: nil
        )
    }

    private func makeModel(guest: Bool = false, id: String = "u1") -> OnboardingModel {
        OnboardingModel(user: makeUser(guest: guest, id: id), storage: storage)
    }

    // MARK: - Step sets

    func testGuestGetsShortenedFlowButKeepsTheAgeGate() {
        let steps = OnboardingStep.steps(isGuest: true)
        XCTAssertTrue(steps.contains(.dateOfBirth), "Guests are never exempt from the age gate")
        XCTAssertTrue(steps.contains(.safety))
        XCTAssertFalse(steps.contains(.photos))
        XCTAssertFalse(steps.contains(.bio))
    }

    func testFullFlowIncludesEveryStep() {
        XCTAssertEqual(OnboardingStep.steps(isGuest: false).count, OnboardingStep.allCases.count)
    }

    // MARK: - Validation

    func testCannotAdvancePastEmptyName() {
        let model = makeModel()
        XCTAssertFalse(model.advance())
        XCTAssertNotNil(model.validationMessage)
        XCTAssertEqual(model.draft.currentStep, .name)
    }

    func testWhitespaceOnlyNameIsRejected() {
        let model = makeModel()
        model.update { $0.displayName = "   " }
        XCTAssertFalse(model.advance())
        XCTAssertEqual(model.draft.currentStep, .name)
    }

    func testValidNameAdvances() {
        let model = makeModel()
        model.update { $0.displayName = "Alex" }
        XCTAssertTrue(model.advance())
        XCTAssertEqual(model.draft.currentStep, .dateOfBirth)
    }

    func testUnderageCannotAdvance() {
        let model = makeModel()
        model.update { $0.displayName = "Alex" }
        model.advance()

        model.update {
            $0.dateOfBirth = Calendar.current.date(byAdding: .year, value: -15, to: Date())
        }
        XCTAssertFalse(model.advance())
        XCTAssertEqual(model.validationMessage, AgeGateFailure.underage.message)
        XCTAssertEqual(model.draft.currentStep, .dateOfBirth)
    }

    func testAdultAdvancesPastAgeGate() {
        let model = makeModel()
        model.update { $0.displayName = "Alex" }
        model.advance()
        model.update {
            $0.dateOfBirth = Calendar.current.date(byAdding: .year, value: -22, to: Date())
        }
        XCTAssertTrue(model.advance())
        XCTAssertEqual(model.draft.currentStep, .gender)
    }

    func testInterestsRequireThree() {
        let model = makeModel()
        model.jumpToStepForTesting(.interests)

        model.update { $0.interests = ["Coffee", "Films"] }
        XCTAssertNotNil(model.validateCurrentStep())

        model.update { $0.interests = ["Coffee", "Films", "Hiking"] }
        XCTAssertNil(model.validateCurrentStep())
    }

    func testSafetyMustBeAcknowledged() {
        let model = makeModel()
        model.jumpToStepForTesting(.safety)

        XCTAssertNotNil(model.validateCurrentStep())
        model.setSafetyAcknowledged(true)
        XCTAssertNil(model.validateCurrentStep())
    }

    // MARK: - Resume

    func testDraftSurvivesRelaunch() {
        let model = makeModel()
        model.update { $0.displayName = "Riley" }
        model.advance()
        model.update {
            $0.dateOfBirth = Calendar.current.date(byAdding: .year, value: -30, to: Date())
        }
        model.advance()
        XCTAssertEqual(model.draft.currentStep, .gender)

        // A new model for the same user — as after a relaunch.
        let resumed = OnboardingModel(user: makeUser(), storage: storage)

        XCTAssertEqual(resumed.draft.currentStep, .gender, "Must resume at the same step")
        XCTAssertEqual(resumed.draft.displayNameForTesting, "Riley", "Must keep answers")
        XCTAssertNotNil(resumed.draft.profile.dateOfBirth)
    }

    /// Drafts are keyed per user; switching accounts must not leak answers.
    func testDraftsDoNotLeakBetweenUsers() {
        let first = OnboardingModel(user: makeUser(id: "user-a"), storage: storage)
        first.update { $0.displayName = "Ada" }

        let second = OnboardingModel(user: makeUser(id: "user-b"), storage: storage)
        XCTAssertEqual(second.draft.profile.displayName, "", "Another user's draft must not leak")
    }

    func testBackNavigationPreservesAnswers() {
        let model = makeModel()
        model.update { $0.displayName = "Jordan" }
        model.advance()
        model.goBack()

        XCTAssertEqual(model.draft.currentStep, .name)
        XCTAssertEqual(model.draft.profile.displayName, "Jordan")
    }

    func testBackFromFirstStepIsANoOp() {
        let model = makeModel()
        model.goBack()
        XCTAssertEqual(model.draft.currentStep, .name)
    }

    // MARK: - Completion

    func testCompletionClearsDraftAndMarksOnboardingDone() async {
        let suite = "test.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suite)!
        let userStore = MockUserStore(defaults: userDefaults)
        let auth = MockAuthenticationService(latency: .milliseconds(1), store: userStore)
        let session = SessionStore(auth: auth)

        session.signIn(with: .guest, hasConsented: true)
        try? await Task.sleep(for: .milliseconds(300))

        guard let user = session.user else { return XCTFail("Expected a signed-in user") }

        let model = OnboardingModel(user: user, storage: storage)
        model.update { profile in
            profile = .completeGuestProfile
        }
        model.setSafetyAcknowledged(true)
        model.jumpToStepForTesting(.review)

        await model.finish(session: session)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNotNil(session.user?.onboardingCompletedAt)
        XCTAssertEqual(session.route, .main)
        XCTAssertNil(storage.load(for: user.id), "Finished draft must be cleared")

        userStore.reset()
    }

    /// A failure at the finish line must leave the draft intact so the user can
    /// resume rather than lose everything they entered.
    func testFailedCompletionKeepsDraft() async {
        let suite = "test.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suite)!
        let userStore = MockUserStore(defaults: userDefaults)
        let auth = MockAuthenticationService(latency: .milliseconds(1), store: userStore)
        let session = SessionStore(auth: auth)

        session.signIn(with: .guest, hasConsented: true)
        try? await Task.sleep(for: .milliseconds(300))
        guard let user = session.user else { return XCTFail("Expected a signed-in user") }

        let model = OnboardingModel(user: user, storage: storage)
        model.update { $0 = .completeGuestProfile }
        model.setSafetyAcknowledged(true)
        model.jumpToStepForTesting(.review)

        auth.nextFailure = .network
        await model.finish(session: session)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNotNil(storage.load(for: user.id), "A failed finish must not discard the draft")
        userStore.reset()
    }

    // MARK: - Completion percentage

    func testCompletionPercentageRises() {
        let empty = ProfileRequirements.completionPercentage(for: Profile(), isGuest: false)
        let full = ProfileRequirements.completionPercentage(for: .completeFullProfile, isGuest: false)
        XCTAssertEqual(empty, 0)
        XCTAssertGreaterThan(full, empty)
        XCTAssertLessThanOrEqual(full, 100)
    }

    func testMissingFieldsForGuestExcludePhotosAndLocation() {
        let missing = ProfileRequirements.missingFields(for: .completeGuestProfile)
        XCTAssertTrue(missing.isEmpty)
    }
}

// MARK: - Test seams

private extension ProfileRequirements {
    static func missingFields(for profile: Profile) -> [ProfileField] {
        missingFields(in: profile, isGuest: true)
    }
}

private extension OnboardingDraft {
    var displayNameForTesting: String { profile.displayName }
}
