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
        case .name: "This is how you'll appear on Baybe."
        case .dateOfBirth: "You must be 18 or older. Your birthday stays private — only your age is shown."
        case .gender: "Shown on your profile."
        case .interestedIn: "Pick as many as you like."
        case .location: "City only. Baybe never shares your exact location."
        case .photos: "Add at least one. Your first photo is your main one."
        case .bio: "A sentence or two. What should someone know before they call you?"
        case .interests: "Pick at least three so we can find better matches."
        case .cameraAndMic: "Baybe is built on live calls, so we need both."
        case .notifications: "So you know when someone wants to talk."
        case .safety: "A few ground rules before your first call."
        case .review: "Here's what others will see."
        }
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

    private let storage: OnboardingDraftStorage
    private let userID: String
    private let photoService: PhotoUploadService

    /// Owned here rather than by `PhotosStep` so an upload survives the user
    /// tapping Continue and walking on — the view is torn down on every step
    /// change, and a queue living there would cancel in-flight uploads.
    private(set) lazy var photoQueue: PhotoUploadQueue = PhotoUploadQueue(
        uid: userID,
        service: photoService,
        currentPhotoCount: { [weak self] in self?.draft.profile.photos.count ?? 0 },
        onUploaded: { [weak self] photo in self?.addUploadedPhoto(photo) }
    )

    /// The same service the queue uploads through, exposed so photo tiles can
    /// read bytes back. One service means an uploaded photo is always readable
    /// by the view that just uploaded it.
    var photoDisplayService: PhotoUploadService { photoService }

    var steps: [OnboardingStep] { OnboardingStep.allCases }

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
        storage: OnboardingDraftStorage = .standard,
        photoService: PhotoUploadService = PhotoServiceFactory.make()
    ) {
        self.storage = storage
        self.userID = user.id
        self.photoService = photoService

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
        // Debounced: this runs on every keystroke of the name and bio fields,
        // and encoding + writing UserDefaults per keystroke is wasted work.
        // Anything that matters more than half a second of typing (step
        // changes, photos, completion) flushes explicitly.
        persistSoon()
    }

    func setSafetyAcknowledged(_ value: Bool) {
        draft.acknowledgedSafety = value
        needsPersist = true
        persistNow()
    }

    func markPermissionExplainerSeen() {
        draft.sawPermissionExplainer = true
        needsPersist = true
        persistNow()
    }

    // MARK: - Persistence

    private var persistTask: Task<Void, Never>?
    private var needsPersist = false

    private func persistSoon() {
        needsPersist = true
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        guard needsPersist else { return }
        needsPersist = false
        storage.save(draft, for: userID)
    }

    // Deliberately no save in deinit: `draft` is main-actor state and a deinit
    // is not. The exposure is bounded — every step change, photo change,
    // toggle, and finish flushes synchronously, so at most ~400ms of *typing*
    // can be lost, and only if the model is torn down mid-keystroke.
    deinit {
        persistTask?.cancel()
    }

    // MARK: - Photos

    /// Called by the queue once bytes are stored. Never call this with a photo
    /// that hasn't uploaded — the type makes that impossible, and that is the
    /// point.
    ///
    /// The photo arrives with the order the queue reserved for it at selection
    /// time. It is inserted by that order — not appended — so a batch keeps the
    /// user's selection order however the uploads interleave. While uploads are
    /// still in flight the orders are left sparse (their slots are reserved);
    /// they are compacted once the queue settles.
    private func addUploadedPhoto(_ photo: ProfilePhoto) {
        update { profile in
            let index = profile.photos.firstIndex { $0.order > photo.order }
                ?? profile.photos.endIndex
            profile.photos.insert(photo, at: index)

            if photoQueue.items.isEmpty {
                Self.renumber(&profile.photos)
            }
        }
        // An uploaded photo is server state; the draft must never lag it.
        persistNow()
    }

    /// Removes the photo and deletes its bytes.
    ///
    /// The record goes immediately so the grid responds at once; the Storage
    /// delete follows and is allowed to fail. An orphaned object costs a
    /// fraction of a cent and is swept by the account-deletion job — blocking
    /// the UI on it, or worse restoring the tile on failure, would be a far
    /// worse trade.
    func removePhoto(id: String) {
        guard let photo = draft.profile.photos.first(where: { $0.id == id }) else { return }

        update { profile in
            profile.photos.removeAll { $0.id == id }
            Self.renumber(&profile.photos)
        }
        persistNow()

        Task { [photoService] in
            try? await photoService.delete(remotePath: photo.remotePath)
        }
    }

    /// Drag-to-reorder. Index 0 is the primary photo.
    func movePhotos(from source: IndexSet, to destination: Int) {
        update { profile in
            profile.photos.move(fromOffsets: source, toOffset: destination)
            Self.renumber(&profile.photos)
        }
        persistNow()
    }

    /// `order` must always match array position, because it is what Firestore
    /// sorts on when the profile is read back. Letting the two drift is how the
    /// primary photo silently changes on reload.
    private static func renumber(_ photos: inout [ProfilePhoto]) {
        for index in photos.indices {
            photos[index].order = index
        }
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
            needsPersist = true
            persistNow()
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
        needsPersist = true
        persistNow()
    }

    #if DEBUG
    /// Test seam: jump straight to a step instead of walking the flow to reach
    /// it. Not called from app code — validation for a step is otherwise only
    /// reachable by satisfying every step before it, which makes each test a
    /// test of the whole flow. DEBUG-only so it cannot ship.
    func jumpToStepForTesting(_ step: OnboardingStep) {
        draft.currentStep = step
        validationMessage = nil
    }
    #endif

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
            // `profile.photos` only ever holds uploaded photos, so this is
            // already "at least one photo whose bytes are stored".
            if profile.photos.isEmpty {
                // Distinguish "you haven't picked one" from "yours is still
                // going" — otherwise a user who picked a photo two seconds ago
                // is told to add one, which reads as the app losing it.
                if photoQueue.isUploading {
                    return "Hang on — your photo is still uploading."
                }
                if photoQueue.hasFailures {
                    return "Your photo didn't upload. Retry it or pick another."
                }
                return "Please add at least one photo."
            }
            return nil

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
            let missing = ProfileRequirements.missingFields(in: profile)
            guard missing.isEmpty else {
                return "Still needed: \(missing.map(\.label).joined(separator: ", "))."
            }
            return nil
        }
    }

    // MARK: - Completion

    /// Writes the profile through `SessionStore` and marks onboarding done.
    ///
    /// Ordering matters. The profile is written first and onboarding is marked
    /// complete only if that write succeeded — the reverse order can mark an
    /// account complete whose profile never landed, and `hasValidProfileState`
    /// would then bounce it straight back to onboarding with no explanation.
    ///
    /// The draft is only discarded after both succeed, so a failure leaves the
    /// user able to resume rather than losing everything.
    func finish(session: SessionStore) async {
        // Whatever happens next, the draft on disk matches what's on screen —
        // a failure mid-finish must resume with nothing missing.
        persistNow()

        if let failure = validateCurrentStep() {
            validationMessage = failure
            return
        }

        // The last line of defence for "no completion without a real photo".
        // Reachable in ways the photos step alone is not: a user can pass the
        // photos step, reach review, and delete their only photo on the way —
        // review's own check would still pass, because it reads the same
        // requirements the photos step already satisfied.
        guard let failure = uploadGateFailure() else {
            isFinishing = true
            defer { isFinishing = false }

            await session.updateProfile(draft.profile)
            guard session.error == nil else { return }

            await session.completeOnboarding()
            guard session.error == nil else { return }

            storage.clear(for: userID)
            return
        }
        validationMessage = failure
    }

    /// Why completion is not allowed yet, or nil if it is.
    func uploadGateFailure() -> String? {
        if photoQueue.isUploading {
            return "Hang on — your photo is still uploading."
        }
        if draft.profile.photos.isEmpty {
            return photoQueue.hasFailures
                ? "Your photo didn't upload. Retry it or pick another."
                : "Please add at least one photo."
        }
        return nil
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
