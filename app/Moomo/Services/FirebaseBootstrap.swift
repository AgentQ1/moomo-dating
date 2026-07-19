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
        configureAppCheck()
        FirebaseApp.configure()
        hasConfigured = true
        #endif
    }

    /// Opt-in switch for App Check: `MOOMO_ENABLE_APP_CHECK=1` in the
    /// environment, or `-MOOMO_ENABLE_APP_CHECK` as a launch argument.
    private static var isAppCheckEnabled: Bool {
        ProcessInfo.processInfo.environment["MOOMO_ENABLE_APP_CHECK"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-MOOMO_ENABLE_APP_CHECK")
    }

    /// App Check: App Attest on devices, the debug provider in DEBUG builds
    /// (simulators and CI register debug tokens in the Firebase console).
    ///
    /// OFF unless explicitly enabled via `MOOMO_ENABLE_APP_CHECK`. The App
    /// Check API (`firebaseappcheck.googleapis.com`) is currently disabled for
    /// this project, so installing a provider factory just makes every token
    /// fetch fail with a repeated 403 SERVICE_DISABLED. Before turning the
    /// flag on: enable the Firebase App Check API in the console and register
    /// this build's debug token, or the same 403s come back.
    ///
    /// This attests the APP; enforcement is server-side and currently OFF
    /// (`enforceAppCheck` per callable, `backend/README.md`) until the app is
    /// registered in the App Check console — flipping enforcement first would
    /// lock every real user out.
    private static func configureAppCheck() {
        #if canImport(FirebaseAppCheck)
        guard isAppCheckEnabled else { return }
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
