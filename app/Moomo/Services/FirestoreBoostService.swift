import Foundation

#if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import FirebaseFirestore
import FirebaseFunctions

/// Boost state from `boosts/{uid}`, activation through the backend.
///
/// The state document is server-owned: a client-writable boost would be a
/// self-granted entitlement the moment boosts cost money (StoreKit is
/// Phase 6; boosts are free-allowance during the beta and nothing in the UI
/// may imply payment).
final class FirestoreBoostService: BoostService, @unchecked Sendable {

    /// Mirrors `BOOST_DAILY_ALLOWANCE` in backend/functions/src/shared.ts.
    /// Only used to render state before the first activation creates the
    /// document — the callable is the authority.
    static let dailyAllowance = 3
    static let refillInterval: TimeInterval = 24 * 60 * 60

    private let uid: String
    private var db: Firestore { Firestore.firestore() }

    private let broadcaster: StreamBroadcaster<BoostState>
    private var listener: ListenerRegistration?

    init(uid: String) {
        self.uid = uid
        broadcaster = StreamBroadcaster(
            BoostState(activeUntil: nil, remainingBoosts: Self.dailyAllowance)
        )

        listener = db.collection(FirestorePath.boosts).document(uid)
            .addSnapshotListener { [broadcaster] snapshot, error in
                guard let snapshot else {
                    FirestoreListeners.report(error, in: "boost")
                    return
                }
                FirestoreListeners.recovered("boost")
                broadcaster.send(Self.state(from: snapshot))
            }
    }

    deinit {
        listener?.remove()
    }

    var stateStream: AsyncStream<BoostState> { broadcaster.stream() }

    func state() async -> BoostState { broadcaster.value }

    @discardableResult
    func activate() async throws -> BoostState {
        do {
            let response = try await FunctionsClient.call(.activateBoost)
            let remaining = response["remainingBoosts"] as? Int ?? 0
            let untilMillis = response["activeUntilMillis"] as? Double
            let state = BoostState(
                activeUntil: untilMillis.map { Date(timeIntervalSince1970: $0 / 1000) },
                remainingBoosts: remaining
            )
            broadcaster.send(state)
            return state
        } catch {
            throw Self.mapped(error)
        }
    }

    /// The backend refuses with a machine-readable message; surface it as the
    /// same typed errors the UI already explains.
    private static func mapped(_ error: Error) -> Error {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              nsError.code == FunctionsErrorCode.failedPrecondition.rawValue else {
            return error
        }
        switch nsError.localizedDescription {
        case "alreadyActive": return BoostError.alreadyActive
        case "noneRemaining": return BoostError.noneRemaining
        default: return error
        }
    }

    private static func state(from document: DocumentSnapshot) -> BoostState {
        guard document.exists else {
            // No document until the first activation: the full daily
            // allowance is genuinely available (the backend grants it lazily).
            return BoostState(activeUntil: nil, remainingBoosts: dailyAllowance)
        }
        let grantedAt = SocialDecoding.date(document.get("grantedAt"))
        let stale = grantedAt.map { Date().timeIntervalSince($0) >= refillInterval } ?? true

        return BoostState(
            activeUntil: SocialDecoding.date(document.get("activeUntil")),
            // Same lazy-refill arithmetic as the backend: a day after the
            // last grant, the allowance is back regardless of the stored count.
            remainingBoosts: stale
                ? dailyAllowance
                : document.get("remainingBoosts") as? Int ?? 0
        )
    }
}
#endif
