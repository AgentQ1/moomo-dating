import Foundation
import os

#if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import FirebaseFirestore
import FirebaseFunctions

/// Discover, served by the `getDiscoveryFeed` callable.
///
/// The raw `publicProfiles` query this service used to run is gone — rules
/// now deny client `list` on that collection entirely, because any
/// authenticated script could page the whole base and dump every profile
/// (production-readiness audit P0-3). The backend composes the feed instead:
/// bounded, block-filtered in both directions, compatibility-filtered with
/// the same table matchmaking pairs by, rate-limited, and cursor-free. This
/// service renders what it is handed.
///
/// Presence stays a client heartbeat on our OWN document, but throttled and
/// quantized (audit P1-1) — see `PresenceHeartbeat` for the write-hotspot
/// story. `wantsToTalk` is set by the matchmaking backend when someone is
/// genuinely waiting in the queue, never by a client about itself.
///
/// Block filtering also happens in the wrapping
/// `BlockFilteringDiscoveryService` — redundant with the server's filter on
/// purpose (defense in depth, and the mock world's guarantee stays honest).
struct FirestoreDiscoveryService: DiscoveryService {

    /// Active within this window renders as "online". The feed computes
    /// `isOnline` server-side from the same constant (discovery.ts
    /// ONLINE_WINDOW_MS) — the two must move together.
    static let onlineWindow: TimeInterval = 5 * 60

    /// One tracker for the whole process: rebuilding the service graph
    /// (tab switches, sign-in cycles) must not bypass the throttle.
    private static let heartbeats = PresenceHeartbeatTracker()

    private static let log = Logger(subsystem: "com.moomo.dating", category: "discovery")

    let uid: String

    private var db: Firestore { Firestore.firestore() }

    func loadDiscovery() async throws -> DiscoveryState {
        // Heartbeat first, best-effort: our own presence must never block
        // seeing other people. Throttled — every Discover open writing an
        // indexed server timestamp was the audit's first-to-break hotspot.
        if Self.heartbeats.markSendable(uid: uid) {
            try? await db.collection(FirestorePath.publicProfiles).document(uid).setData([
                "uid": uid,
                "lastActiveAt": FieldValue.serverTimestamp(),
                "activityBucket": Timestamp(date: PresenceHeartbeat.activityBucket()),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
        }

        let payload: [String: Any]
        do {
            payload = try await FunctionsClient.call(.getDiscoveryFeed)
        } catch {
            // Log the REAL failure before classifying — "unauthenticated"
            // here means App Check rejected the app (register the debug
            // token / App Attest in Firebase console, backend/README.md);
            // "not-found" means the backend deploy is missing
            // getDiscoveryFeed. Neither is a connectivity problem, and
            // neither may render as one.
            let nsError = error as NSError
            let classified = DiscoveryErrorClassifier.classify(error)
            Self.log.error("""
            getDiscoveryFeed failed: [\(nsError.domain, privacy: .public) \
            \(nsError.code)] \(nsError.localizedDescription, privacy: .public) \
            → \(String(describing: classified), privacy: .public)
            """)
            #if canImport(FirebaseAuth)
            // DEBUG-only inside: uid, ID-token fetch, App Check mint, full
            // userInfo — the dump that distinguishes "no session" from
            // "App Check refused this install".
            await DiscoveryDiagnostics.logCallableFailure("getDiscoveryFeed", error: error)
            #endif
            throw classified
        }

        let candidates = DiscoveryFeedDecoding.candidates(fromFeedPayload: payload)

        // The hero card features whoever is genuinely waiting on a call,
        // otherwise the most recently active person.
        let featured = candidates.first(where: \.wantsToTalk) ?? candidates.first

        return DiscoveryState(
            featured: featured,
            nearby: Array(candidates.filter { $0.id != featured?.id }.prefix(8)),
            // Levels are a server-computed engagement stat that doesn't exist
            // yet; everyone is honestly level 1 until it does.
            level: 1,
            // Communities aren't built; the header simply omits the row.
            community: nil
        )
    }

}
#endif
