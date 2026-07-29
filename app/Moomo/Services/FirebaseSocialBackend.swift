import Foundation

#if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import FirebaseFirestore
import FirebaseFunctions

/// The callable functions the app is allowed to invoke. One list, so a typo'd
/// function name is impossible and the client↔backend contract is greppable.
/// Names must match the exports in `backend/functions/src/index.ts`.
enum CloudFunction: String {
    case joinMatchmakingQueue
    case leaveMatchmakingQueue
    case acceptCallInvite
    case declineCallInvite
    case getDiscoveryFeed
    case endCallSession
    case getCallMediaToken
    case submitCallDecision
    case blockUser
    case reportUser
    case unmatchUser
    case activateBoost
    case deleteAccount
}

/// Thin wrapper over `Functions` so services share one call style and one
/// error surface.
enum FunctionsClient {
    static func call(
        _ function: CloudFunction,
        _ payload: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let callable = Functions.functions().httpsCallable(function.rawValue)
        let result = try await callable.call(payload)
        return result.data as? [String: Any] ?? [:]
    }
}

/// Snapshot listeners as `AsyncStream`s — the shape every mock already
/// exposes, so view models cannot tell the difference. The listener is
/// removed the moment the stream's consumer goes away.
extension Query {
    func snapshotStream() -> AsyncStream<QuerySnapshot> {
        AsyncStream { continuation in
            let registration = addSnapshotListener { snapshot, error in
                if let snapshot {
                    continuation.yield(snapshot)
                } else {
                    FirestoreListeners.report(error, in: "query.snapshotStream")
                }
            }
            continuation.onTermination = { _ in registration.remove() }
        }
    }
}

extension DocumentReference {
    func snapshotStream() -> AsyncStream<DocumentSnapshot> {
        AsyncStream { continuation in
            let registration = addSnapshotListener { snapshot, error in
                if let snapshot {
                    continuation.yield(snapshot)
                } else {
                    FirestoreListeners.report(error, in: "document.snapshotStream")
                }
            }
            continuation.onTermination = { _ in registration.remove() }
        }
    }
}

/// Decoding for the denormalised participant/profile maps the backend writes.
/// Hand-decoded for the same reason as `FirestoreProfileStore`: the wire shape
/// and the model should be free to diverge without a migration.
enum SocialDecoding {

    /// A `DiscoveryCandidate` from a backend `participants[uid]` summary.
    ///
    /// `isOnline` is deliberately false: a summary is a snapshot from pairing
    /// time and must not claim presence it cannot know. Live presence comes
    /// from `publicProfiles.lastActiveAt` in Discover only.
    static func candidate(fromParticipant data: [String: Any]?, uid: String) -> DiscoveryCandidate {
        DiscoveryCandidate(
            id: uid,
            displayName: (data?["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Someone",
            age: data?["age"] as? Int ?? 0,
            city: data?["city"] as? String ?? "",
            photoPath: (data?["photoPath"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isOnline: false,
            wantsToTalk: false,
            pronoun: pronoun(fromGender: data?["gender"] as? String)
        )
    }

    /// Renders "Talk to Him/Her/Them". One table for the whole app — the
    /// mapping itself lives on `CandidatePronoun` (DiscoveryPresence.swift)
    /// so the feed decoder shares it.
    static func pronoun(fromGender gender: String?) -> CandidatePronoun {
        CandidatePronoun(genderRawValue: gender)
    }

    /// The other participant's uid in a two-person `participantIds` array.
    static func peerID(in participantIds: [String], me: String) -> String? {
        participantIds.first { $0 != me }
    }

    static func date(_ value: Any?) -> Date? {
        (value as? Timestamp)?.dateValue()
    }
}
#endif
