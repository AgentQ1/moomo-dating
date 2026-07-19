import UIKit
import os

#if canImport(FirebaseAuth)
import FirebaseAuth
#endif

/// One place to see which app-verification path phone auth will take.
/// Filter the console on subsystem `com.moomo.dating`, category `apns`:
/// a token line means silent verification is possible; a failure line means
/// every phone verification will fall back to the reCAPTCHA web page.
private let apnsLog = Logger(subsystem: "com.moomo.dating", category: "apns")

/// The UIKit delegate behind the SwiftUI app, installed via
/// `@UIApplicationDelegateAdaptor`. It exists for one reason: Firebase Phone
/// Auth verifies app integrity with a **silent APNs push**, and a pure SwiftUI
/// lifecycle never registers for remote notifications nor receives the
/// delegate callbacks that carry the token and the push. Without this bridge,
/// `verifyPhoneNumber` fails with the "app delegate swizzling" error.
///
/// Nothing here prompts the user. Registering for *remote* notifications is
/// token plumbing only — permission dialogs gate visible notifications, which
/// onboarding still defers to first use.
///
/// On simulators, or until the APNs auth key is configured for the project,
/// registration fails or the push never arrives; Firebase Auth then falls
/// back to its reCAPTCHA web flow, whose callback lands in
/// `FirebaseBootstrap.handle(url:)` via the registered URL scheme.
@MainActor
final class MoomoAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // THE configuration point, deliberately not `MoomoApp.init`:
        // FirebaseAuth's eager init needs `UIApplication.sharedApplication`
        // to exist, which is guaranteed here and not there (see
        // `FirebaseBootstrap.configureIfNeeded`). This still precedes every
        // view and service: SwiftUI completes this callback before it
        // connects scenes or instantiates any `StateObject`.
        FirebaseBootstrap.configureIfNeeded()

        // APNs token plumbing for phone verification. Pointless against the
        // mock backend, and a hard fail on unprovisioned dev boxes, so it is
        // gated the same way the rest of Firebase is.
        if case .firebase = BackendConfiguration.current {
            apnsLog.info("Registering for remote notifications (phone-auth silent push)")
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        apnsLog.info("APNs token received (\(deviceToken.count) bytes) — silent phone verification available")
        #if canImport(FirebaseAuth)
        // `.unknown` lets the SDK work out sandbox vs production from the
        // build, so debug and App Store builds both verify.
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
        #endif
        // No FCM/push feature exists yet; when one lands, its token handling
        // joins this method rather than replacing it.
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Simulators and machines without an APNs environment land here.
        // Firebase Auth falls back to reCAPTCHA and the phone flow still
        // completes — the log is the only trace of why the web page appeared.
        apnsLog.error("APNs registration FAILED: \(error.localizedDescription) — phone verification will use the reCAPTCHA fallback")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        #if canImport(FirebaseAuth)
        // The silent verification push. Consumed entirely by the SDK — it
        // must not fall through to any future app push handling.
        if Auth.auth().canHandleNotification(userInfo) {
            apnsLog.info("Silent verification push handled by FirebaseAuth")
            completionHandler(.noData)
            return
        }
        #endif
        // No other remote-notification handling exists yet.
        completionHandler(.noData)
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        // Same funnel as SwiftUI's `onOpenURL`: phone verification's
        // reCAPTCHA callback.
        FirebaseBootstrap.handle(url: url)
    }
}
