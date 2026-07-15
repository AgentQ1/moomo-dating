import Foundation
import SwiftUI

/// The single source of truth for who is signed in and where they belong.
///
/// Every screen reads auth state and the current user from here. No view model
/// keeps its own copy of the user or profile — they mutate through
/// `updateProfile`, and the change flows back out via `@Published`. That rule
/// is what stops the two-conflicting-profiles class of bug.
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
    /// The provider currently authenticating, for per-button spinners.
    @Published private(set) var signingInWith: AuthProvider?
    /// The last provider tried, so a retryable failure knows what to retry.
    @Published private(set) var lastAttemptedProvider: AuthProvider?
    @Published var error: AuthError?

    let auth: AuthenticationService
    private let credentials: CredentialProviding
    private var observationTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?

    init(
        auth: AuthenticationService,
        credentials: CredentialProviding = LiveCredentialProvider()
    ) {
        self.auth = auth
        self.credentials = credentials
        observe()
    }

    deinit {
        observationTask?.cancel()
        signInTask?.cancel()
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
    private func apply(_ user: User?) {
        self.user = user

        guard let user else {
            route = .welcome
            return
        }
        route = user.hasValidProfileState ? .main : .onboarding
    }

    // MARK: - Sign in

    /// Consent is enforced here, not only in the UI. A screen that forgets to
    /// disable its buttons still cannot create an account without it.
    func signIn(with provider: AuthProvider, hasConsented: Bool) {
        guard hasConsented else {
            error = .consentRequired
            return
        }
        guard signingInWith == nil else { return }

        signingInWith = provider
        lastAttemptedProvider = provider
        error = nil

        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await credentials.credential(for: provider)
                _ = try await auth.signIn(with: credential, consent: .now())
            } catch let authError as AuthError {
                // Backing out is a choice, not a failure — no alert.
                if authError != .cancelled { error = authError }
            } catch is CancellationError {
                // Superseded or torn down; nothing to report.
            } catch {
                self.error = .unknown(error.localizedDescription)
            }
            signingInWith = nil
        }
    }

    /// Retry the last failed attempt.
    func retry(provider: AuthProvider) {
        error = nil
        signIn(with: provider, hasConsented: true)
    }

    /// Abandon an in-flight sign-in.
    func cancelSignIn() {
        signInTask?.cancel()
        signingInWith = nil
    }

    // MARK: - Guest linking

    /// Upgrade the signed-in guest to a real account, keeping its uid and
    /// everything built under it.
    func linkGuestAccount(with provider: AuthProvider) async {
        guard user?.isGuest == true else { return }
        signingInWith = provider
        defer { signingInWith = nil }

        do {
            let credential = try await credentials.credential(for: provider)
            _ = try await auth.linkGuestAccount(with: credential)
        } catch let authError as AuthError {
            if authError != .cancelled { error = authError }
        } catch {
            self.error = .unknown(error.localizedDescription)
        }
    }

    // MARK: - Profile

    /// The only way profile changes reach storage.
    func updateProfile(_ profile: Profile) async {
        do {
            try await auth.updateProfile(profile)
        } catch {
            self.error = .unknown(error.localizedDescription)
        }
    }

    func completeOnboarding() async {
        do {
            try await auth.completeOnboarding()
        } catch {
            self.error = .unknown(error.localizedDescription)
        }
    }

    func signOut() {
        Task {
            try? await auth.signOut()
        }
    }
}
