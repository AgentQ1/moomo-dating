import XCTest
@testable import Moomo

/// Onboarding validation, resume-after-relaunch, and completion.
@MainActor
final class OnboardingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var storage: OnboardingDraftStorage!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        storage = OnboardingDraftStorage(defaults: defaults)
    }

    private func makeUser(id: String = "u1") -> User {
        User(
            id: id,
            authProvider: .phone,
            consent: .now(),
            profile: Profile(),
            createdAt: Date(),
            onboardingCompletedAt: nil
        )
    }

    private func makeModel(id: String = "u1") -> OnboardingModel {
        OnboardingModel(user: makeUser(id: id), storage: storage)
    }

    /// Signs into the mock backend through the real phone flow — the only way
    /// a session begins.
    private func signInWithPhone(_ auth: MockAuthenticationService) async {
        _ = try? await auth.sendCode(to: "+15550100200")
        _ = try? await auth.signIn(
            verificationID: MockAuthenticationService.mockVerificationID,
            code: MockAuthenticationService.validVerificationCode,
            consent: .now()
        )
    }

    // MARK: - Step sets

    func testFlowIncludesEveryStepForEveryone() {
        // The guest short flow is gone with anonymous auth: one flow, and it
        // always includes the age gate, photos, and safety.
        let steps = OnboardingStep.allCases
        XCTAssertTrue(steps.contains(.dateOfBirth))
        XCTAssertTrue(steps.contains(.photos))
        XCTAssertTrue(steps.contains(.safety))
    }

    // MARK: - Dating intention

    /// The flow, not `allCases`, decides what the user walks through.
    func testDatingIntentionIsInTheFlowBesideTheOtherMatchingFilter() {
        let flow = OnboardingStep.flow
        XCTAssertEqual(Set(flow).count, flow.count, "A step must not appear twice")
        XCTAssertEqual(
            Set(flow), Set(OnboardingStep.allCases),
            "Every declared step must be reachable — a case missing from `flow` is dead UI"
        )

        guard let interestedIn = flow.firstIndex(of: .interestedIn),
              let intention = flow.firstIndex(of: .datingIntention)
        else { return XCTFail("Both matching filters must be in the flow") }
        XCTAssertEqual(intention, interestedIn + 1, "The two matching filters are asked together")
    }

    /// Raw values are persisted in the resume draft. Renumbering them would
    /// resume an in-flight user on a different step than they left.
    func testStepRawValuesAreStableForPersistedDrafts() {
        XCTAssertEqual(OnboardingStep.name.rawValue, 0)
        XCTAssertEqual(OnboardingStep.interestedIn.rawValue, 3)
        XCTAssertEqual(OnboardingStep.location.rawValue, 4)
        XCTAssertEqual(OnboardingStep.review.rawValue, 11)
        XCTAssertEqual(
            OnboardingStep.datingIntention.rawValue, 12,
            "New steps append; they never renumber the existing ones"
        )
    }

    func testCannotAdvancePastDatingIntentionWithoutChoosing() {
        let model = makeModel()
        model.jumpToStepForTesting(.datingIntention)

        XCTAssertFalse(model.advance())
        XCTAssertNotNil(model.validationMessage)
        XCTAssertEqual(model.draft.currentStep, .datingIntention)

        model.update { $0.datingIntention = .longTerm }
        XCTAssertTrue(model.advance())
        XCTAssertEqual(model.draft.currentStep, .location)
    }

    /// The onboarding requirement must not leak into the app-entry gate: every
    /// account that predates intentions has nil, and gating on it there would
    /// bounce the entire existing userbase back into onboarding.
    func testExistingProfilesWithoutAnIntentionStayValid() {
        var profile = Profile()
        profile.displayName = "Sam"
        profile.dateOfBirth = Calendar.current.date(byAdding: .year, value: -30, to: Date())
        profile.gender = .woman
        profile.interestedIn = [.everyone]
        profile.location = CityCatalog.cities[0]
        profile.photos = [ProfilePhoto(id: "p1", remotePath: "users/u/photos/p1.jpg", order: 0)]
        profile.datingIntention = nil

        XCTAssertTrue(
            ProfileRequirements.missingFields(in: profile).isEmpty,
            "A nil dating intention must never block an existing account from the app"
        )
    }

    /// What onboarding collects is what gets written — the completion path
    /// hands the whole draft profile to SessionStore.
    func testFinishedDraftCarriesTheChosenIntention() {
        let model = makeModel()
        model.update { $0.datingIntention = .shortTermOpenToLong }
        XCTAssertEqual(model.draft.profile.datingIntention, .shortTermOpenToLong)
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

        await signInWithPhone(auth)
        try? await Task.sleep(for: .milliseconds(300))

        guard let user = session.user else { return XCTFail("Expected a signed-in user") }

        let model = OnboardingModel(user: user, storage: storage)
        model.update { profile in
            profile = .completeFullProfile
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

        await signInWithPhone(auth)
        try? await Task.sleep(for: .milliseconds(300))
        guard let user = session.user else { return XCTFail("Expected a signed-in user") }

        let model = OnboardingModel(user: user, storage: storage)
        model.update { $0 = .completeFullProfile }
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
        let empty = ProfileRequirements.completionPercentage(for: Profile())
        let full = ProfileRequirements.completionPercentage(for: .completeFullProfile)
        XCTAssertEqual(empty, 0)
        XCTAssertGreaterThan(full, empty)
        XCTAssertLessThanOrEqual(full, 100)
    }

    func testMissingFieldsRequirePhotosAndLocation() {
        // A profile with only the identity basics is not enterable: photos
        // and location are required for everyone.
        let missing = ProfileRequirements.missingFields(in: .identityOnlyProfile)
        XCTAssertTrue(missing.contains(.photos))
        XCTAssertTrue(missing.contains(.location))

        XCTAssertTrue(ProfileRequirements.missingFields(in: .completeFullProfile).isEmpty)
    }
}

// MARK: - Test seams

private extension OnboardingDraft {
    var displayNameForTesting: String { profile.displayName }
}
