import Foundation
import SwiftUI

/// The steps of onboarding, in order.
enum OnboardingStep: Int, CaseIterable, Identifiable, Codable {
    case name
    case dateOfBirth
    case gender
    case interestedIn
    case location
    case photos
    case bio
    case interests
    case cameraAndMic
    case notifications
    case safety
    case review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .name: "What's your name?"
        case .dateOfBirth: "When's your birthday?"
        case .gender: "How do you identify?"
        case .interestedIn: "Who would you like to meet?"
        case .location: "Where are you?"
        case .photos: "Add your photos"
        case .bio: "Tell us about you"
        case .interests: "What are you into?"
        case .cameraAndMic: "Camera & microphone"
        case .notifications: "Stay in the loop"
        case .safety: "Be real, be kind"
        case .review: "Looking good"
        }
    }

    var subtitle: String {
        switch self {
        case .name: "This is how you'll appear on Moomo."
        case .dateOfBirth: "You must be 18 or older. Your birthday stays private — only your age is shown."
        case .gender: "Shown on your profile."
        case .interestedIn: "Pick as many as you like."
        case .location: "City only. Moomo never shares your exact location."
        case .photos: "Add at least one. Your first photo is your main one."
        case .bio: "A sentence or two. What should someone know before they call you?"
        case .interests: "Pick at least three so we can find better matches."
        case .cameraAndMic: "Moomo is built on live calls, so we need both."
        case .notifications: "So you know when someone wants to talk."
        case .safety: "A few ground rules before your first call."
        case .review: "Here's what others will see."
        }
    }

    /// Guests get a shortened flow — enough for a temporary profile and the
    /// age gate, without demanding photos or a bio from someone just looking.
    static func steps(isGuest: Bool) -> [OnboardingStep] {
        guard isGuest else { return allCases }
        return [.name, .dateOfBirth, .gender, .interestedIn, .cameraAndMic, .safety, .review]
    }
}

/// Everything onboarding collects, and the resume point.
///
/// Persisted on every change so a relaunch mid-flow returns to the same step
/// with the same answers.
struct OnboardingDraft: Codable, Equatable {
    var profile: Profile = Profile()
    var currentStep: OnboardingStep = .name
    var acknowledgedSafety: Bool = false
    /// Whether the explainer was shown. Permissions are never requested before
    /// this is true.
    var sawPermissionExplainer: Bool = false
}

/// The one authoritative onboarding state model.
///
/// Owns the draft; the step views bind into it and hold no profile state of
/// their own. On completion the draft is written through `SessionStore`, which
/// is the only writer to the account.
@MainActor
final class OnboardingModel: ObservableObject {

    @Published private(set) var draft: OnboardingDraft
    @Published private(set) var isFinishing = false
    @Published var validationMessage: String?

    let isGuest: Bool
    private let storage: OnboardingDraftStorage
    private let userID: String

    var steps: [OnboardingStep] { OnboardingStep.steps(isGuest: isGuest) }

    var currentIndex: Int {
        steps.firstIndex(of: draft.currentStep) ?? 0
    }

    var progress: Double {
        guard steps.count > 1 else { return 1 }
        return Double(currentIndex) / Double(steps.count - 1)
    }

    var isLastStep: Bool { draft.currentStep == steps.last }

    init(
        user: User,
        storage: OnboardingDraftStorage = .standard
    ) {
        self.isGuest = user.isGuest
        self.storage = storage
        self.userID = user.id

        // Resume where they left off, seeded from whatever the account already
        // has (an Apple display name, say).
        if let saved = storage.load(for: user.id) {
            self.draft = saved
        } else {
            var draft = OnboardingDraft()
            draft.profile = user.profile
            self.draft = draft
        }
    }

    // MARK: - Editing
    //
    // Every mutation funnels through here so persistence can't be forgotten.

    func update(_ mutate: (inout Profile) -> Void) {
        mutate(&draft.profile)
        validationMessage = nil
        persist()
    }

    func setSafetyAcknowledged(_ value: Bool) {
        draft.acknowledgedSafety = value
        persist()
    }

    func markPermissionExplainerSeen() {
        draft.sawPermissionExplainer = true
        persist()
    }

    private func persist() {
        storage.save(draft, for: userID)
    }

    // MARK: - Navigation

    /// Validates the current step and advances. Returns false and sets
    /// `validationMessage` if the step isn't satisfied.
    @discardableResult
    func advance() -> Bool {
        guard let failure = validateCurrentStep() else {
            guard let next = steps[safe: currentIndex + 1] else { return false }
            withAnimation(Motion.transition) {
                draft.currentStep = next
            }
            persist()
            return true
        }
        validationMessage = failure
        return false
    }

    func goBack() {
        guard let previous = steps[safe: currentIndex - 1] else { return }
        validationMessage = nil
        withAnimation(Motion.transition) {
            draft.currentStep = previous
        }
        persist()
    }

    /// Test seam: jump straight to a step instead of walking the flow to reach
    /// it. Not called from app code — validation for a step is otherwise only
    /// reachable by satisfying every step before it, which makes each test a
    /// test of the whole flow.
    func jumpToStepForTesting(_ step: OnboardingStep) {
        draft.currentStep = step
        validationMessage = nil
    }

    // MARK: - Validation

    /// The message to show, or nil when the step passes.
    func validateCurrentStep() -> String? {
        let profile = draft.profile

        switch draft.currentStep {
        case .name:
            let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return "Please enter your name." }
            if name.count < 2 { return "That name looks too short." }
            if name.count > 30 { return "Please keep your name under 30 characters." }
            return nil

        case .dateOfBirth:
            guard let dob = profile.dateOfBirth else {
                return "Please scroll to set your date of birth."
            }
            if case .invalid(let failure) = AgeGate.validate(birthDate: dob) {
                return failure.message
            }
            return nil

        case .gender:
            return profile.gender == nil ? "Please choose an option." : nil

        case .interestedIn:
            return profile.interestedIn.isEmpty ? "Please choose at least one." : nil

        case .location:
            return profile.location == nil ? "Please set your city." : nil

        case .photos:
            return profile.photos.isEmpty ? "Please add at least one photo." : nil

        case .bio:
            if profile.bio.count > 300 { return "Please keep your bio under 300 characters." }
            return nil

        case .interests:
            return profile.interests.count < 3 ? "Please pick at least three." : nil

        case .cameraAndMic, .notifications:
            return nil

        case .safety:
            return draft.acknowledgedSafety ? nil : "Please accept the community guidelines."

        case .review:
            let missing = ProfileRequirements.missingFields(in: profile, isGuest: isGuest)
            guard missing.isEmpty else {
                return "Still needed: \(missing.map(\.label).joined(separator: ", "))."
            }
            return nil
        }
    }

    // MARK: - Completion

    /// Writes the profile through `SessionStore` and marks onboarding done.
    /// The draft is only discarded after both succeed, so a failure here
    /// leaves the user able to resume rather than losing everything.
    func finish(session: SessionStore) async {
        guard validateCurrentStep() == nil else {
            validationMessage = validateCurrentStep()
            return
        }
        isFinishing = true
        defer { isFinishing = false }

        await session.updateProfile(draft.profile)
        await session.completeOnboarding()

        if session.error == nil {
            storage.clear(for: userID)
        }
    }
}

/// Disk persistence for the in-progress draft, keyed per user so switching
/// accounts can't cross-contaminate.
struct OnboardingDraftStorage {
    static let standard = OnboardingDraftStorage(defaults: .standard)

    private let defaults: UserDefaults
    private let prefix = "onboarding.draft."

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func save(_ draft: OnboardingDraft, for userID: String) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: prefix + userID)
    }

    func load(for userID: String) -> OnboardingDraft? {
        guard let data = defaults.data(forKey: prefix + userID) else { return nil }
        return try? JSONDecoder().decode(OnboardingDraft.self, from: data)
    }

    func clear(for userID: String) {
        defaults.removeObject(forKey: prefix + userID)
    }

    /// Drops every stored draft. UI-test reset only.
    func resetAll() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

extension Array {
    /// Bounds-checked subscript — step navigation indexes off the ends.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
