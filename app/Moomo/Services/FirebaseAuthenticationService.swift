import Foundation
import os

#if canImport(FirebaseAuth)
import FirebaseAuth
import FirebaseCore

/// Raw backend errors, before they are mapped to user-facing copy. The copy
/// deliberately says only "we couldn't send the code" — this log is where the
/// actual Firebase error code and reason survive. Filter the console on
/// subsystem `com.moomo.dating`, category `auth`.
private let authLog = Logger(subsystem: "com.moomo.dating", category: "auth")

/// Real authentication against Firebase Phone Auth.
///
/// Sign-in is one exchange: `sendCode` sends the SMS, `signIn` trades the
/// typed code for a Firebase session. The same phone number always resolves to
/// the same Firebase uid, so an existing user lands back in their account and
/// a new number creates one.
///
/// Mirrors `MockAuthenticationService` exactly, so `SessionStore` — and every
/// screen above it — is unchanged by the swap. The mock survives for tests and
/// previews only; production never falls back to it.
final class FirebaseAuthenticationService: AuthenticationService, @unchecked Sendable {

    private let auth: Auth
    private let profiles: ProfileStore
    private let lock = NSLock()
    private var _currentUser: User?
    /// False until the persisted session is resolved: either the auth listener
    /// confirmed there is no signed-in user, or a restore/sign-in published a
    /// real one. Until then `_currentUser`'s nil means "unknown", not "signed
    /// out", and `userStream` must not replay it — doing so flashed the welcome
    /// screen at every returning user for the frame before restore finished.
    private var hasPublishedInitialSessionState = false
    private var continuations: [UUID: AsyncStream<User?>.Continuation] = [:]
    private var authListener: AuthStateDidChangeListenerHandle?
    /// The in-flight profile restore. Superseded (cancelled) whenever the auth
    /// state changes again, so a slow restore can never publish a stale user
    /// over a newer sign-in or sign-out.
    private var restoreTask: Task<Void, Never>?

    /// Photo storage, used only by account deletion. Same backend the photo
    /// queue uploads through, so deletion removes exactly what upload created.
    private let photos: PhotoUploadService

    init(
        auth: Auth = Auth.auth(),
        profiles: ProfileStore = FirestoreProfileStore(),
        photos: PhotoUploadService = PhotoServiceFactory.make()
    ) {
        self.auth = auth
        self.profiles = profiles
        self.photos = photos
        observeAuthState()
    }

    deinit {
        if let authListener {
            auth.removeStateDidChangeListener(authListener)
        }
        lock.lock()
        let task = restoreTask
        lock.unlock()
        task?.cancel()
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
            let resolved = hasPublishedInitialSessionState
            lock.unlock()

            // Before the first publish there is nothing truthful to replay:
            // the subscriber (SessionStore) stays on `.launching` until the
            // session is confirmed signed-out or the real user is restored.
            if resolved {
                continuation.yield(user)
            }
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

            // Supersede any restore still running for a previous auth state.
            lock.lock()
            let previous = restoreTask
            let initialStateResolved = hasPublishedInitialSessionState
            lock.unlock()
            previous?.cancel()

            guard let firebaseUser else {
                // FirebaseAuth 11 restores the persisted session from the
                // keychain ASYNCHRONOUSLY: on a cold launch this listener can
                // fire nil first and then fire again with the restored user a
                // beat later. Before anything has been published, nil is
                // therefore "possibly still restoring", not "signed out" —
                // publishing it immediately flashed the welcome screen at
                // every returning user. Hold the verdict briefly; the second
                // listener fire cancels it (via restoreTask supersede above)
                // and restores the user without welcome ever rendering. A
                // genuinely signed-out launch just shows the splash for the
                // grace period. After the initial resolve, nil is a real
                // sign-out/revocation and publishes immediately.
                if initialStateResolved {
                    publish(nil)
                } else {
                    let task = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        self?.publish(nil)
                    }
                    lock.lock()
                    restoreTask = task
                    lock.unlock()
                }
                return
            }

            // Phone OTP is the only sign-in method. A session restored from an
            // install that predates it — anonymous, or OAuth without a linked
            // number — cannot exist in this world: end it rather than resume
            // it. The old profile stays in Firestore untouched; only the dead
            // session is dropped. Its owner reaches it again the moment they
            // verify the same phone number, which signs into the same uid.
            guard !firebaseUser.isAnonymous, firebaseUser.phoneNumber != nil else {
                try? self.auth.signOut()
                publish(nil)
                return
            }

            // Load the profile that belongs to this uid. Until it arrives the
            // user is not published: routing depends on profile state, and
            // publishing a hollow user would bounce a fully-onboarded person
            // back into onboarding for a frame.
            let task = Task {
                await self.restoreProfile(for: firebaseUser)
            }
            lock.lock()
            restoreTask = task
            lock.unlock()
        }
    }

    /// Bootstraps the profile for a restored session, retrying on failure.
    ///
    /// A profile that can't be read is not a reason to claim the user is
    /// signed out — publishing nil here would bounce a signed-in user to the
    /// welcome screen on a bad connection and loop them through sign-in.
    /// Instead: if a user with this uid is already published, they stay
    /// published; otherwise the app stays on the launch screen while this
    /// retries with backoff until it succeeds or a newer auth state cancels it.
    private func restoreProfile(for firebaseUser: FirebaseAuth.User) async {
        var delay: Duration = .seconds(1)

        while !Task.isCancelled {
            do {
                let user = try await profiles.bootstrap(uid: firebaseUser.uid, consent: nil)
                guard !Task.isCancelled else { return }
                publish(attachingPhone(to: user))
                return
            } catch is CancellationError {
                return
            } catch {
                // The session itself is intact — only the profile read failed.
                // If this uid is already published (e.g. sign-in just completed
                // and the listener re-fired), there is nothing to fix.
                if currentUser?.id == firebaseUser.uid { return }

                // Offline cold launch: the bootstrap transaction needs the
                // network, but a returning user's profile is already in the
                // local Firestore cache. Publish the cached user so the app
                // opens instead of sitting on the splash screen until the
                // network comes back; the next successful bootstrap (the
                // retry below, or the next launch) reconciles the document. A
                // cold install with no cache keeps retrying.
                if let cached = await profiles.loadCached(uid: firebaseUser.uid) {
                    guard !Task.isCancelled else { return }
                    publish(attachingPhone(to: cached))
                }

                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
            }
        }
    }

    /// The verified phone number lives on the Firebase user, not in Firestore.
    /// Every published `User` carries it.
    private func attachingPhone(to user: User) -> User {
        var user = user
        user.phoneNumber = auth.currentUser?.phoneNumber
        return user
    }

    // MARK: - Phone OTP

    /// Sends the SMS. APNs handles the silent app verification on devices;
    /// Firebase falls back to reCAPTCHA in the simulator, which is why no
    /// UI delegate is passed — the SDK finds the key window itself.
    func sendCode(to phoneNumber: String) async throws -> String {
        do {
            return try await PhoneAuthProvider.provider(auth: auth)
                .verifyPhoneNumber(phoneNumber, uiDelegate: nil)
        } catch {
            let nsError = error as NSError
            authLog.error("""
                verifyPhoneNumber FAILED: domain=\(nsError.domain, privacy: .public) \
                code=\(nsError.code) \
                description=\(nsError.localizedDescription, privacy: .public) \
                userInfo=\(String(describing: nsError.userInfo), privacy: .public)
                """)
            switch Self.map(error) {
            case .network: throw AuthError.network
            case .invalidPhoneNumber: throw AuthError.invalidPhoneNumber
            case .tooManyAttempts: throw AuthError.tooManyAttempts
            case .cancelled: throw AuthError.cancelled
            // Anything else — quota, configuration, SDK internals — is, to the
            // person waiting for a text, one fact: the SMS did not go out.
            default: throw AuthError.smsSendFailed
            }
        }
    }

    /// Exchanges the OTP for a session. Firebase resolves the verified number
    /// to its uid — existing account or a fresh one — and the idempotent
    /// bootstrap then fetches or creates the profile documents. Relaunching or
    /// re-signing-in never duplicates or resets a profile.
    func signIn(verificationID: String, code: String, consent: ConsentRecord) async throws -> User {
        let credential = PhoneAuthProvider.provider(auth: auth).credential(
            withVerificationID: verificationID,
            verificationCode: code
        )

        do {
            let result = try await auth.signIn(with: credential)
            let user = try await profiles.bootstrap(uid: result.user.uid, consent: consent)
            let published = attachingPhone(to: user)
            publish(published)
            return published
        } catch let error as AuthError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - Profile

    func updateProfile(_ profile: Profile) async throws {
        guard let uid = auth.currentUser?.uid else { throw AuthError.unknown("Not signed in.") }
        let user = try await profiles.update(uid: uid, profile: profile)
        publish(attachingPhone(to: user))
    }

    func completeOnboarding() async throws {
        guard let uid = auth.currentUser?.uid else { throw AuthError.unknown("Not signed in.") }
        let user = try await profiles.markOnboardingComplete(uid: uid)
        publish(attachingPhone(to: user))
    }

    // MARK: - Sign out

    /// Ends the session only.
    ///
    /// The Firebase user is deliberately *not* deleted: sign-out is not account
    /// deletion. Only user-scoped local drafts are cleared.
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

    // MARK: - Account deletion

    /// One server-side cascade: the `deleteAccount` callable removes the
    /// account's documents, its server-owned social data (matches,
    /// conversations, sessions, queue, boosts), its Storage photos, and
    /// finally the Auth user. The client cannot do this itself — rules deny
    /// client deletes of `users/{uid}` and everything server-owned — and a
    /// partial client-side deletion would orphan social data.
    ///
    /// If the callable fails, nothing local is torn down: the account is
    /// intact and the user simply retries.
    func deleteAccount() async throws {
        guard let firebaseUser = auth.currentUser else {
            throw AuthError.unknown("Not signed in.")
        }
        let uid = firebaseUser.uid

        #if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
        do {
            _ = try await FunctionsClient.call(.deleteAccount)
        } catch {
            throw Self.map(error)
        }
        #else
        throw AuthError.unknown("Account deletion requires the full Firebase SDK.")
        #endif

        OnboardingDraftStorage.standard.clear(for: uid)
        // The Auth user is already gone server-side; drop the dead session.
        try? auth.signOut()
        publish(nil)
    }

    // MARK: - Error mapping

    /// Maps Firebase errors onto the app's error model, so `SessionStore` and
    /// the UI never see raw SDK errors.
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
        case .invalidPhoneNumber, .missingPhoneNumber:
            return .invalidPhoneNumber
        case .invalidVerificationCode:
            return .invalidVerificationCode
        case .invalidVerificationID, .sessionExpired:
            return .verificationExpired
        case .tooManyRequests, .quotaExceeded:
            return .tooManyAttempts
        case .webContextCancelled:
            // Firebase's web context — the reCAPTCHA fallback of phone
            // verification — was dismissed by the user.
            return .cancelled
        case .operationNotAllowed:
            // Phone auth is disabled in the Firebase console. A terminal
            // configuration fault — retrying will never help.
            return .unknown("Phone sign-in is not enabled for this app.")
        case .requiresRecentLogin:
            // Firebase demands a fresh sign-in for destructive operations.
            return .unknown("For security, sign in again and then retry.")
        default:
            return .unknown(nsError.localizedDescription)
        }
    }

    // MARK: - Publishing

    private func publish(_ user: User?) {
        lock.lock()
        hasPublishedInitialSessionState = true
        _currentUser = user
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(user) }
    }
}
#endif
