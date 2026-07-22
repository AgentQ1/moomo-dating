import Foundation

/// The auth story in front of the real Discover feed. Three duties:
///
/// 1. **Gate** — the backend is never called without a live Firebase
///    session. Routing already guarantees this (`MainTabView` exists only
///    for a published user, which requires the restored session), but the
///    guarantee belongs on the service too, where a test can pin it.
/// 2. **Retry** — one `unauthenticated` gets one second chance, after a
///    forced ID-token refresh and an App Check mint attempt. That recovers
///    the transient causes (stale token an instant after restore, a debug
///    token registered since the last attempt) without hammering a backend
///    that keeps saying no.
/// 3. **Diagnose** — a 401 that survives the retry is refined by
///    `DiscoveryErrorClassifier.refineUnauthenticated` into `.sessionExpired`
///    or an App Check diagnostic, so the card never shows a bare
///    "unauthenticated" when the client can see which credential is missing.
///
/// Pure Swift on purpose: the three facts it needs arrive as closures
/// (`DiscoveryDiagnostics` supplies the Firebase-backed ones), so the whole
/// policy is unit-testable without Firebase.
struct AuthGatedDiscoveryService: DiscoveryService {

    let base: DiscoveryService
    /// The signed-in Firebase uid, nil when there is no session.
    let currentUID: @Sendable () -> String?
    /// Force-refreshes the ID token. False when the refresh itself failed.
    let refreshSession: @Sendable () async -> Bool
    /// Nil when an App Check token can be minted right now; otherwise the
    /// reason it can't (which is the diagnostic shown in DEBUG).
    let appCheckProblem: @Sendable () async -> String?

    func loadDiscovery() async throws -> DiscoveryState {
        guard currentUID() != nil else { throw DiscoveryError.sessionExpired }

        do {
            return try await base.loadDiscovery()
        } catch let error as DiscoveryError where error.isBareUnauthenticated {
            // The session can have died mid-flight (sign-out, revocation) —
            // that is a routing matter, not a retry matter.
            guard currentUID() != nil else { throw DiscoveryError.sessionExpired }

            // Refresh + probe BEFORE the retry: the retry then flies with a
            // fresh ID token, and the App Check probe warms the token cache
            // if the blocker (an unregistered debug token) was just fixed.
            _ = await refreshSession()
            let appCheckIssue = await appCheckProblem()

            do {
                return try await base.loadDiscovery()
            } catch let retryError as DiscoveryError where retryError.isBareUnauthenticated {
                throw DiscoveryErrorClassifier.refineUnauthenticated(
                    hasSession: currentUID() != nil,
                    appCheckProblem: appCheckIssue
                )
            }
        }
    }
}
