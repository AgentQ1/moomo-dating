import Foundation
import os

#if canImport(FirebaseAuth)
import FirebaseAuth
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseAppCheck)
import FirebaseAppCheck
#endif

/// The Firebase side of Discover's auth diagnostics: the facts
/// `AuthGatedDiscoveryService` gates and refines on, plus the DEBUG dump
/// that turns a bare `unauthenticated` into something fixable.
///
/// Why this exists (2026-07-22 incident): after the backend deployed with
/// `enforceAppCheck: true`, Discover showed only "(Debug: unauthenticated)".
/// The 401 is ambiguous by construction — App Check enforcement and
/// `requireAuth` share it — and the client logs said nothing about WHICH
/// credential the request lacked. These probes make the two causes
/// distinguishable on-device: the session/ID-token side via Auth, the
/// attestation side by attempting an App Check token mint.
///
/// Filter the console on subsystem `com.moomo.dating`, category
/// `discovery-auth`.
enum DiscoveryDiagnostics {

    private static let log = Logger(subsystem: "com.moomo.dating", category: "discovery-auth")

    /// The signed-in uid, nil when no session exists.
    static func currentUID() -> String? {
        Auth.auth().currentUser?.uid
    }

    /// Force-refreshes the ID token, so the gate's one retry flies with a
    /// token the backend cannot call stale. False when the refresh failed —
    /// which is itself diagnostic (a revoked or disabled account).
    static func refreshIDToken() async -> Bool {
        guard let user = Auth.auth().currentUser else {
            log.error("refreshIDToken: currentUser is nil — no session to refresh")
            return false
        }
        do {
            _ = try await user.getIDToken(forcingRefresh: true)
            log.info("refreshIDToken: ok for uid \(user.uid, privacy: .public)")
            return true
        } catch {
            let nsError = error as NSError
            log.error("""
                refreshIDToken FAILED for uid \(user.uid, privacy: .public): \
                [\(nsError.domain, privacy: .public) \(nsError.code)] \
                \(nsError.localizedDescription, privacy: .public)
                """)
            return false
        }
    }

    /// Attempts to mint an App Check token — exactly what the Functions SDK
    /// does before a callable. Nil means App Check is healthy; otherwise the
    /// reason, which in DEBUG names the debug token that needs registering.
    static func appCheckProblem() async -> String? {
        #if canImport(FirebaseAppCheck)
        do {
            let token = try await AppCheck.appCheck().token(forcingRefresh: false)
            log.info("App Check token minted ok (expires \(token.expirationDate, privacy: .public))")
            return nil
        } catch {
            let nsError = error as NSError
            log.error("""
                App Check token fetch FAILED: \
                [\(nsError.domain, privacy: .public) \(nsError.code)] \
                \(nsError.localizedDescription, privacy: .public) \
                userInfo=\(String(describing: nsError.userInfo), privacy: .public)
                """)
            #if DEBUG
            if let debugToken = currentDebugToken() {
                return """
                token mint failed (\(nsError.localizedDescription)). This build \
                attests with the DEBUG provider — register this install's debug \
                token in Firebase console → moomo-c7a37 → App Check → Apps → \
                Manage debug tokens: \(debugToken)
                """
            }
            #endif
            return "token mint failed (\(nsError.localizedDescription))"
        }
        #else
        return "FirebaseAppCheck is not linked"
        #endif
    }

    #if DEBUG && canImport(FirebaseAppCheck)
    /// The debug token THIS install presents to the exchange endpoint. Reads
    /// (or mints and persists) the same UserDefaults-backed value the
    /// factory's provider uses, so what we print is what the backend sees.
    static func currentDebugToken() -> String? {
        guard let app = FirebaseApp.app() else { return nil }
        return AppCheckDebugProvider(app: app)?.currentDebugToken()
    }
    #endif

    /// The full DEBUG dump around a failed callable: who was signed in,
    /// whether an ID token can be fetched, whether App Check can mint, and
    /// the raw error including userInfo. No-op in release builds.
    static func logCallableFailure(_ function: String, error: Error) async {
        #if DEBUG
        let nsError = error as NSError
        let user = Auth.auth().currentUser
        log.error("""
            \(function, privacy: .public) diagnostics — \
            uid=\(user?.uid ?? "nil (currentUser is nil)", privacy: .public) \
            error=[\(nsError.domain, privacy: .public) \(nsError.code)] \
            \(nsError.localizedDescription, privacy: .public) \
            userInfo=\(String(describing: nsError.userInfo), privacy: .public)
            """)
        if let user {
            do {
                let token = try await user.getIDToken()
                log.info("\(function, privacy: .public): ID token fetch ok (\(token.count) chars)")
            } catch {
                log.error("""
                    \(function, privacy: .public): ID token fetch FAILED: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
        _ = await appCheckProblem() // Logs its own verdict either way.
        #endif
    }
}
#endif
