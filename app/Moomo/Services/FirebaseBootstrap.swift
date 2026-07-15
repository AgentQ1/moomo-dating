import Foundation

#if canImport(FirebaseCore)
import FirebaseCore
#endif

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

/// Configures Firebase, exactly once.
///
/// `FirebaseApp.configure()` traps if called twice. The guard here is not
/// belt-and-braces: SwiftUI may re-run `App.init` (previews, scene
/// reconnection), and a second call would crash the app on launch.
enum FirebaseBootstrap {

    private static var hasConfigured = false

    /// Call once, as early as possible. Safe to call repeatedly.
    static func configureIfNeeded() {
        guard !hasConfigured else { return }
        hasConfigured = true

        #if canImport(FirebaseCore)
        // Only configure when a real config is present. `BackendConfiguration`
        // has already refused the AI project's plist by this point.
        guard case .firebase = BackendConfiguration.current else { return }
        guard FirebaseApp.app() == nil else { return }

        FirebaseApp.configure()
        configureGoogleSignIn()
        #endif
    }

    /// Google Sign-In needs the OAuth client id from the plist. Firebase does
    /// not set this up for us.
    private static func configureGoogleSignIn() {
        #if canImport(GoogleSignIn) && canImport(FirebaseCore)
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            // No CLIENT_ID in the plist means no iOS OAuth client exists for
            // this app. Apple and guest still work; Google will fail with a
            // clear provider error rather than a crash.
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        #endif
    }

    /// Whether Google Sign-In is actually usable. False when the plist carries
    /// no OAuth client, which is a configuration fault, not a runtime one.
    static var isGoogleSignInConfigured: Bool {
        #if canImport(GoogleSignIn) && canImport(FirebaseCore)
        return FirebaseApp.app()?.options.clientID != nil
        #else
        return false
        #endif
    }

    /// Forwards the OAuth callback. Without this, Google sign-in returns to a
    /// blank screen instead of the app.
    @MainActor
    static func handle(url: URL) -> Bool {
        #if canImport(GoogleSignIn)
        return GIDSignIn.sharedInstance.handle(url)
        #else
        return false
        #endif
    }
}
