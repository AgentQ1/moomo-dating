import Foundation

#if canImport(FirebaseCore)
import FirebaseCore
#endif

#if canImport(FirebaseAppCheck)
import FirebaseAppCheck
#endif

#if canImport(FirebaseAuth)
import FirebaseAuth
#endif

/// Configures Firebase, exactly once.
///
/// `FirebaseApp.configure()` traps if called twice. The guard here is not
/// belt-and-braces: SwiftUI may re-run `App.init` (previews, scene
/// reconnection), and a second call would crash the app on launch.
enum FirebaseBootstrap {

    private static var hasConfigured = false

    /// Call from `MoomoAppDelegate.didFinishLaunching`, and nowhere earlier.
    /// Safe to call repeatedly.
    ///
    /// NOT from `MoomoApp.init`: that runs before UIApplicationMain, and
    /// FirebaseAuth — created eagerly inside `FirebaseApp.configure()` —
    /// captures `UIApplication.sharedApplication` on a background queue. If
    /// the shared application does not exist yet, Auth silently skips its
    /// APNs/notification managers and never retries: phone verification then
    /// fails forever with the "app delegate swizzling" error, and the first
    /// APNs token delivery force-unwraps nil and crashes.
    ///
    /// `hasConfigured` must only become true once Firebase actually is —
    /// setting it on entry would let an early return (mock backend) latch
    /// "configured" while `FirebaseApp.app()` is still nil, and every later
    /// Auth/Firestore touch would hit the unconfigured state.
    static func configureIfNeeded() {
        guard !hasConfigured else { return }

        #if canImport(FirebaseCore)
        // Only configure when a real config is present. `BackendConfiguration`
        // has already refused the AI project's plist by this point. Mock mode
        // never marks Firebase configured.
        guard case .firebase = BackendConfiguration.current else { return }

        // No `FirebaseApp.app() != nil` pre-check: asking before configure()
        // is precisely what logs the "default Firebase app has not yet been
        // configured" warning. `hasConfigured` is the sole double-configure
        // guard; nothing else in this process calls `FirebaseApp.configure()`.

        // App Check's factory must be set BEFORE configure() or the first
        // token fetch races the default provider.
        runConfigurationSteps(
            installAppCheckFactory: { configureAppCheck() },
            configureFirebase: { FirebaseApp.configure() }
        )
        hasConfigured = true

        #if DEBUG
        logAppCheckDebugToken()
        #endif
        #endif
    }

    /// The bootstrap sequence as one path with the two steps injectable, so
    /// a wiring test can pin the ordering App Check depends on: the factory
    /// installed strictly before `FirebaseApp.configure()`. Installed after,
    /// it loses the race for the first token fetch and every callable goes
    /// out unattested — which an enforcing backend refuses wholesale.
    static func runConfigurationSteps(
        installAppCheckFactory: () -> Void,
        configureFirebase: () -> Void
    ) {
        installAppCheckFactory()
        configureFirebase()
    }

    #if DEBUG
    /// Prints this install's App Check debug token, loudly, on every DEBUG
    /// launch. DEBUG builds attest with the debug provider — simulators AND
    /// devices — and the backend enforces App Check on every callable, so
    /// an install whose token isn't registered is refused everything with a
    /// bare `unauthenticated`. The token to register belongs one copy-paste
    /// away, not buried in the SDK's own logging.
    private static func logAppCheckDebugToken() {
        #if canImport(FirebaseAppCheck) && canImport(FirebaseCore)
        guard !isAppCheckDisabled,
              let app = FirebaseApp.app(),
              let provider = AppCheckDebugProvider(app: app) else { return }
        print("""
        ─────────────────────────────────────────────────────────────────
        [Moomo] App Check DEBUG token for this install:
        [Moomo]   \(provider.currentDebugToken())
        [Moomo] Register it once: Firebase console → moomo-c7a37 →
        [Moomo]   App Check → Apps → Moomo (iOS) → ⋮ → Manage debug tokens.
        [Moomo] Unregistered, every callable answers 'unauthenticated'.
        ─────────────────────────────────────────────────────────────────
        """)
        #endif
    }
    #endif

    /// Opt-OUT switch for App Check: `MOOMO_DISABLE_APP_CHECK=1` in the
    /// environment, or `-MOOMO_DISABLE_APP_CHECK` as a launch argument.
    /// For local development against a project whose App Check API is off —
    /// a provider with the API disabled just logs repeated 403
    /// SERVICE_DISABLED token failures.
    private static var isAppCheckDisabled: Bool {
        ProcessInfo.processInfo.environment["MOOMO_DISABLE_APP_CHECK"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-MOOMO_DISABLE_APP_CHECK")
    }

    /// App Check: App Attest on devices, the debug provider in DEBUG builds
    /// (simulators and CI register debug tokens in the Firebase console).
    ///
    /// ON by default (production-readiness audit P0-2): the backend now sets
    /// `enforceAppCheck: true` on every callable, so a client without a
    /// provider is locked out the moment that backend deploys. Deploy order
    /// and the console steps (enable the App Check API, register App Attest
    /// + each simulator's debug token, watch metrics before deploying
    /// enforcement) live in `backend/README.md` "App Check".
    ///
    /// This attests the APP; token fetch failures are non-fatal client-side
    /// (requests simply go out without a token — and are then refused by an
    /// enforcing backend).
    private static func configureAppCheck() {
        #if canImport(FirebaseAppCheck)
        guard !isAppCheckDisabled else { return }
        AppCheck.setAppCheckProviderFactory(MoomoAppCheckProviderFactory())
        #endif
    }

    /// Forwards auth callback URLs to Firebase Auth, which claims phone
    /// verification's reCAPTCHA return. Without this the flow comes back to a
    /// blank screen instead of the app.
    @MainActor
    static func handle(url: URL) -> Bool {
        #if canImport(FirebaseAuth)
        // Guarded: Auth.auth() traps if Firebase was never configured, which
        // is exactly the mock-mode case.
        if case .firebase = BackendConfiguration.current {
            return Auth.auth().canHandle(url)
        }
        #endif
        return false
    }
}

#if canImport(FirebaseAppCheck)
/// App Attest for real devices; the debug provider under DEBUG so simulators
/// and test runs work (their debug tokens are registered in the console).
private final class MoomoAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if DEBUG
        AppCheckDebugProvider(app: app)
        #else
        AppAttestProvider(app: app)
        #endif
    }
}
#endif
