import Foundation

#if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import FirebaseFirestore

/// Matches from Firestore, decisions through the backend.
///
/// The invariant the mock stated — a `Match` exists iff both people liked
/// each other — is now enforced where it must be: `submitCallDecision` is the
/// only code that can mint one, and the rules deny client writes. This class
/// just watches `matches` and forwards decisions.
final class FirestoreMatchService: MatchService, @unchecked Sendable {

    private let uid: String
    private var db: Firestore { Firestore.firestore() }

    private let broadcaster = StreamBroadcaster<[Match]>([])
    private var listener: ListenerRegistration?

    init(uid: String) {
        self.uid = uid

        listener = db.collection(FirestorePath.matches)
            .whereField("participantIds", arrayContains: uid)
            .order(by: "createdAt", descending: true)
            .limit(to: 100)
            .addSnapshotListener { [broadcaster, uid] snapshot, error in
                guard let snapshot else {
                    FirestoreListeners.report(error, in: "matches")
                    return
                }
                FirestoreListeners.recovered("matches")
                broadcaster.send(snapshot.documents.compactMap {
                    Self.match(from: $0, me: uid)
                })
            }
    }

    deinit {
        listener?.remove()
    }

    var matchesStream: AsyncStream<[Match]> { broadcaster.stream() }

    func matches() async -> [Match] { broadcaster.value }

    func submitDecision(
        _ decision: UserDecision,
        about candidate: DiscoveryCandidate,
        callSessionID: String?
    ) async throws -> DecisionOutcome {
        // Decisions are always about a call that happened; the backend
        // verifies we were a participant of that exact session.
        guard let callSessionID else {
            throw MatchServiceError.decisionWithoutCall
        }

        let response = try await FunctionsClient.call(.submitCallDecision, [
            "sessionId": callSessionID,
            "decision": decision.rawValue
        ])

        switch response["outcome"] as? String {
        case "passed":
            return .passed
        case "likeSent":
            return .likeSent
        case "matched":
            guard let payload = response["match"] as? [String: Any],
                  let match = Self.match(fromCallablePayload: payload) else {
                throw MatchServiceError.malformedResponse
            }
            return .matched(match)
        default:
            throw MatchServiceError.malformedResponse
        }
    }

    // MARK: - Decoding

    private static func match(from document: QueryDocumentSnapshot, me: String) -> Match? {
        guard
            let participantIds = document.get("participantIds") as? [String],
            let peerID = SocialDecoding.peerID(in: participantIds, me: me),
            let conversationID = document.get("conversationId") as? String
        else { return nil }

        let participants = document.get("participants") as? [String: [String: Any]]
        return Match(
            id: document.documentID,
            candidate: SocialDecoding.candidate(fromParticipant: participants?[peerID], uid: peerID),
            createdAt: SocialDecoding.date(document.get("createdAt")) ?? Date(),
            conversationID: conversationID
        )
    }

    private static func match(fromCallablePayload payload: [String: Any]) -> Match? {
        guard
            let id = payload["id"] as? String,
            let conversationID = payload["conversationId"] as? String,
            let candidateData = payload["candidate"] as? [String: Any],
            let candidateID = candidateData["uid"] as? String
        else { return nil }

        let createdAtMillis = payload["createdAtMillis"] as? Double ?? Date().timeIntervalSince1970 * 1000
        return Match(
            id: id,
            candidate: SocialDecoding.candidate(fromParticipant: candidateData, uid: candidateID),
            createdAt: Date(timeIntervalSince1970: createdAtMillis / 1000),
            conversationID: conversationID
        )
    }
}

enum MatchServiceError: LocalizedError, Equatable {
    /// A decision was submitted with no call session attached.
    case decisionWithoutCall
    /// The backend answered with something this client doesn't understand.
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .decisionWithoutCall, .malformedResponse:
            "That didn't go through. Please try again."
        }
    }
}
#endif
