import Foundation
import SwiftUI

/// The single source of truth for who is signed in and where they belong.
///
/// Every screen reads auth state and the current user from here. No view model
/// keeps its own copy of the user or profile — they mutate through
/// `updateProfile`, and the change flows back out via `@Published`. That rule
/// is what stops the two-conflicting-profiles class of bug.
///
/// Sign-in itself lives in `PhoneAuthModel`: it is multi-step screen state
/// (number → SMS → code) that dies with the welcome screen. Only the outcome
/// reaches this store, through the auth service's `userStream`.
@MainActor
final class SessionStore: ObservableObject {

    /// Where the app should be right now. Derived, never set by a screen.
    enum Route: Equatable {
        /// Still working out whether there's a persisted session.
        case launching
        case welcome
        /// Signed in, but the profile isn't usable yet.
        case onboarding
        case main
    }

    @Published private(set) var route: Route = .launching
    @Published private(set) var user: User?
    @Published var error: AuthError?

    let auth: AuthenticationService
    private var observationTask: Task<Void, Never>?

    init(auth: AuthenticationService) {
        self.auth = auth
        observe()
    }

    deinit {
        observationTask?.cancel()
    }

    private func observe() {
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await user in auth.userStream {
                guard !Task.isCancelled else { return }
                apply(user)
            }
        }
    }

    /// The routing rule.
    ///
    /// A returning user skips the welcome screen **only** when their profile
    /// state is actually valid — consent present and current, onboarding
    /// finished, required fields intact. Anything less and they resume
    /// onboarding rather than landing in a half-built app.
    ///
    /// Missing or stale consent is the exception: it routes to **welcome**, not
    /// onboarding. Onboarding has no consent step, so sending a consent-less
    /// user there is a dead end — they can fill in every field, tap "Start
    /// meeting people", write it all to Firestore, and still fail
    /// `hasValidProfileState` on the consent check. Routing then re-derives
    /// `.onboarding`, the screen never changes, and nothing explains why.
    ///
    /// That is reachable whenever an account outlives its first write: the
    /// auth-state listener bootstraps with `consent: nil` (it has no consent to
    /// record and must not invent one), so a document created on that path has
    /// no consent fields and the account is soft-locked forever.
    ///
    /// Welcome is where consent is given, and signing in from there records it
    /// against the same uid without touching the profile — so this recovers the
    /// account instead of stranding it.
    private func apply(_ user: User?) {
        self.user = user

        guard let user else {
            route = .welcome
            return
        }
        guard user.hasRecordedCurrentConsent else {
            route = .welcome
            return
        }
        route = user.hasValidProfileState ? .main : .onboarding
    }

    // MARK: - Profile

    /// The only way profile changes reach storage. Returns whether the save
    /// landed, for callers whose next step depends on it (deleting photo
    /// bytes must wait for the record change to be confirmed).
    @discardableResult
    func updateProfile(_ profile: Profile) async -> Bool {
        do {
            try await auth.updateProfile(profile)
            return true
        } catch let authError as AuthError {
            self.error = authError
        } catch {
            self.error = .unknown("Your profile could not be saved. Please try again.")
        }
        return false
    }

    func completeOnboarding() async {
        do {
            try await auth.completeOnboarding()
        } catch let authError as AuthError {
            self.error = authError
        } catch {
            self.error = .unknown("Your profile could not be saved. Please try again.")
        }
    }

    func signOut() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await auth.signOut()
            } catch {
                // A failed sign-out leaves the session in place; saying nothing
                // would strand the user on a screen that looks signed out.
                self.error = .unknown("Could not sign out. Please try again.")
            }
        }
    }

    // MARK: - Account deletion

    /// True while a deletion is running, so the UI can disable the control.
    @Published private(set) var isDeletingAccount = false

    /// Permanently deletes the account. On success the auth service publishes
    /// nil and routing lands on welcome; on failure the existing error alert
    /// explains, and the session is untouched.
    func deleteAccount() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        do {
            try await auth.deleteAccount()
        } catch let authError as AuthError {
            self.error = authError
        } catch {
            self.error = .unknown("Your account could not be deleted. Please try again.")
        }
    }
}
