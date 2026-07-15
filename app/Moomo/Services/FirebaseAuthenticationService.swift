import Foundation

#if canImport(FirebaseAuth)
import FirebaseAuth
import FirebaseCore

/// Real authentication against Firebase.
///
/// Mirrors `MockAuthenticationService` exactly, so `SessionStore` — and every
/// screen above it — is unchanged by the swap. The mock survives for tests and
/// previews only; production never falls back to it.
final class FirebaseAuthenticationService: AuthenticationService, @unchecked Sendable {

    private let auth: Auth
    private let profiles: ProfileStore
    private let lock = NSLock()
    private var _currentUser: User?
    private var continuations: [UUID: AsyncStream<User?>.Continuation] = [:]
    private var authListener: AuthStateDidChangeListenerHandle?

    init(auth: Auth = Auth.auth(), profiles: ProfileStore = FirestoreProfileStore()) {
        self.auth = auth
        self.profiles = profiles
        observeAuthState()
    }

    deinit {
        if let authListener {
            auth.removeStateDidChangeListener(authListener)
        }
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

    // MARK: - Session restoration

    /// Firebase restores the session itself on launch; this listener is what
    /// turns that into our `User`. It also covers token refresh and revocation,
    /// so a disabled account drops out without the app polling for it.
    private func observeAuthState() {
        authListener = auth.addStateDidChangeListener { [weak self] _, firebaseUser in
            guard let self else { return }

            guard let firebaseUser else {
                publish(nil)
                return
            }

            // Load the profile that belongs to this uid. Until it arrives the
            // user is not published: routing depends on profile state, and
            // publishing a hollow user would bounce a fully-onboarded person
            // back into onboarding for a frame.
            Task {
                do {
                    let user = try await self.profiles.bootstrap(
                        uid: firebaseUser.uid,
                        provider: Self.provider(for: firebaseUser),
                        // Apple hands the display name over exactly once. If it
                        // is still on the Firebase user, this is the last
                        // chance to persist it.
                        providerDisplayName: firebaseUser.displayName,
                        consent: nil
                    )
                    self.publish(user)
                } catch {
                    // A profile that can't be read is not a reason to claim the
                    // user is signed out — that would loop them through
                    // sign-in forever on a bad connection.
                    self.publish(nil)
                }
            }
        }
    }

    /// Anonymous accounts are guests; anything else is permanent.
    private static func provider(for user: FirebaseAuth.User) -> AuthProvider {
        if user.isAnonymous { return .guest }
        for info in user.providerData {
            switch info.providerID {
            case "apple.com": return .apple
            case "google.com": return .google
            default: continue
            }
        }
        return .guest
    }

    // MARK: - Sign in

    func signIn(with credential: ProviderCredential, consent: ConsentRecord) async throws -> User {
        do {
            let result: AuthDataResult

            switch credential {
            case .anonymous:
                result = try await auth.signInAnonymously()
            default:
                result = try await auth.signIn(with: Self.firebaseCredential(for: credential))
            }

            // Idempotent: bootstrap creates the documents on first sight and
            // leaves existing ones alone, so relaunching or re-signing-in never
            // duplicates or resets a profile.
            let user = try await profiles.bootstrap(
                uid: result.user.uid,
                provider: Self.provider(for: result.user),
                providerDisplayName: Self.displayName(from: credential) ?? result.user.displayName,
                consent: consent
            )
            publish(user)
            return user
        } catch let error as AuthError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - Linking

    /// Upgrades the signed-in anonymous account in place: same uid, same
    /// profile, same onboarding progress, no second document.
    func linkGuestAccount(with credential: ProviderCredential) async throws -> User {
        guard let firebaseUser = auth.currentUser else {
            throw AuthError.unknown("Not signed in.")
        }
        guard firebaseUser.isAnonymous else {
            throw AuthError.unknown("Only guest accounts can be linked.")
        }

        do {
            let result = try await firebaseUser.link(
                with: Self.firebaseCredential(for: credential)
            )

            // Same uid — bootstrap updates provider metadata and leaves every
            // onboarding field untouched.
            let user = try await profiles.bootstrap(
                uid: result.user.uid,
                provider: Self.provider(for: result.user),
                providerDisplayName: Self.displayName(from: credential) ?? result.user.displayName,
                consent: nil
            )
            publish(user)
            return user
        } catch let error as NSError where error.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
            // The credential already backs another account. Merging two
            // populated accounts silently would destroy data on one side, so
            // this surfaces rather than guessing which to keep. The guest
            // session is left intact.
            throw AuthError.credentialAlreadyInUse
        } catch let error as NSError where error.code == AuthErrorCode.providerAlreadyLinked.rawValue {
            throw AuthError.credentialAlreadyInUse
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - Profile

    func updateProfile(_ profile: Profile) async throws {
        guard let uid = auth.currentUser?.uid else { throw AuthError.unknown("Not signed in.") }
        let user = try await profiles.update(uid: uid, profile: profile)
        publish(user)
    }

    func completeOnboarding() async throws {
        guard let uid = auth.currentUser?.uid else { throw AuthError.unknown("Not signed in.") }
        let user = try await profiles.markOnboardingComplete(uid: uid)
        publish(user)
    }

    // MARK: - Sign out

    /// Ends the session only.
    ///
    /// The Firebase user is deliberately *not* deleted: sign-out is not account
    /// deletion, and deleting an anonymous user here would silently destroy a
    /// guest's profile the moment they signed out. Only user-scoped local
    /// drafts are cleared.
    func signOut() async throws {
        let uid = auth.currentUser?.uid
        do {
            try auth.signOut()
        } catch {
            throw Self.map(error)
        }
        if let uid {
            OnboardingDraftStorage.standard.clear(for: uid)
        }
        publish(nil)
    }

    // MARK: - Credential mapping

    private static func firebaseCredential(for credential: ProviderCredential) throws -> AuthCredential {
        switch credential {
        case .apple(let idToken, let nonce, _, _):
            // The raw nonce is required: Firebase re-hashes it and compares
            // against the hash Apple signed. Passing anything else here would
            // defeat the replay protection.
            return OAuthProvider.appleCredential(
                withIDToken: idToken,
                rawNonce: nonce,
                fullName: nil
            )

        case .google(let idToken, let accessToken):
            return GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: accessToken
            )

        case .anonymous:
            throw AuthError.unknown("Anonymous has no credential to exchange.")
        }
    }

    /// Apple returns the display name on the first authorization only. Pulling
    /// it off the credential here is the last opportunity to keep it.
    private static func displayName(from credential: ProviderCredential) -> String? {
        if case .apple(_, _, let fullName, _) = credential { return fullName }
        return nil
    }

    // MARK: - Error mapping

    /// Maps Firebase errors onto the existing retryable / cancellation /
    /// terminal model, so `SessionStore` and the UI are unchanged.
    static func map(_ error: Error) -> AuthError {
        let nsError = error as NSError

        guard let code = AuthErrorCode(rawValue: nsError.code) else {
            return .unknown(nsError.localizedDescription)
        }

        switch code {
        case .networkError:
            return .network
        case .userDisabled:
            return .accountDisabled
        case .credentialAlreadyInUse, .emailAlreadyInUse, .providerAlreadyLinked,
             .accountExistsWithDifferentCredential:
            return .credentialAlreadyInUse
        case .webContextCancelled:
            // Provider-level cancellation (the user dismissing Apple's or
            // Google's sheet) is caught in the coordinators and never reaches
            // here; this covers Firebase's own web context being dismissed.
            return .cancelled
        case .invalidCredential, .invalidUserToken, .userTokenExpired:
            return .providerFailed("Sign-in")
        case .operationNotAllowed:
            // The provider is disabled in the Firebase console. A terminal
            // configuration fault — retrying will never help.
            return .providerFailed("This sign-in method is not enabled")
        default:
            return .unknown(nsError.localizedDescription)
        }
    }

    // MARK: - Publishing

    private func publish(_ user: User?) {
        lock.lock()
        _currentUser = user
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(user) }
    }
}
#endif
