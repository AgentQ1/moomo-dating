import Foundation

#if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import FirebaseFirestore

/// Discover served from `publicProfiles`.
///
/// Presence is a heartbeat: each load stamps our own `lastActiveAt`, and the
/// feed is everyone else ordered by theirs — recently-active people first,
/// "online" meaning active in the last five minutes. `wantsToTalk` is set by
/// the matchmaking backend when someone is genuinely waiting in the queue,
/// never by a client about itself.
///
/// Block filtering happens in the wrapping `BlockFilteringDiscoveryService`
/// (same guarantee as the mock world); server-side filtering arrives with the
/// Phase 5 backend feed.
struct FirestoreDiscoveryService: DiscoveryService {

    /// Active within this window renders as "online".
    static let onlineWindow: TimeInterval = 5 * 60

    let uid: String

    private var db: Firestore { Firestore.firestore() }

    func loadDiscovery() async throws -> DiscoveryState {
        // Heartbeat first, best-effort: our own presence must never block
        // seeing other people.
        try? await db.collection(FirestorePath.publicProfiles).document(uid).setData([
            "uid": uid,
            "lastActiveAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)

        // Our own gender + preferences, so the feed shows only people we
        // could actually be paired with. Read fresh each load (it's cached
        // locally) so an edited preference applies on the next refresh.
        let viewer = await Self.viewerPreferences(db: db, uid: uid)

        let snapshot: QuerySnapshot
        do {
            snapshot = try await db.collection(FirestorePath.publicProfiles)
                .order(by: "lastActiveAt", descending: true)
                .limit(to: 25)
                .getDocuments()
        } catch {
            if (error as NSError).code == FirestoreErrorCode.unavailable.rawValue {
                throw DiscoveryError.offline
            }
            throw error
        }

        let now = Date()
        let candidates = snapshot.documents
            .filter { $0.documentID != uid }
            .filter { Self.isCompatible(document: $0, with: viewer) }
            .compactMap { Self.candidate(from: $0, now: now) }

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

    // MARK: - Preference filtering

    /// The viewer's own gender and preferences, from their private document.
    private static func viewerPreferences(
        db: Firestore,
        uid: String
    ) async -> (gender: Gender?, interestedIn: Set<InterestedIn>) {
        guard let data = try? await db.collection(FirestorePath.users)
            .document(uid).getDocument().data()
        else { return (nil, []) }
        return (
            (data["gender"] as? String).flatMap(Gender.init(rawValue:)),
            Set((data["interestedIn"] as? [String] ?? []).compactMap(InterestedIn.init(rawValue:)))
        )
    }

    /// Mutual compatibility against a candidate's public projection. Same
    /// table matchmaking applies server-side — Discover must not advertise a
    /// person the queue would refuse to pair.
    private static func isCompatible(
        document: QueryDocumentSnapshot,
        with viewer: (gender: Gender?, interestedIn: Set<InterestedIn>)
    ) -> Bool {
        let candidate = (
            gender: (document.get("gender") as? String).flatMap(Gender.init(rawValue:)),
            interestedIn: Set(
                (document.get("interestedIn") as? [String] ?? [])
                    .compactMap(InterestedIn.init(rawValue:))
            )
        )
        return MatchPreferences.areMutuallyCompatible(viewer, candidate)
    }

    private static func candidate(
        from document: QueryDocumentSnapshot,
        now: Date
    ) -> DiscoveryCandidate? {
        // A projection that never finished onboarding (no name yet) isn't
        // ready to be shown to strangers.
        guard let displayName = document.get("displayName") as? String,
              !displayName.isEmpty else { return nil }

        let lastActive = SocialDecoding.date(document.get("lastActiveAt"))
        let occupation = document.get("occupation") as? String
        return DiscoveryCandidate(
            id: document.documentID,
            displayName: displayName,
            age: document.get("age") as? Int ?? 0,
            city: document.get("city") as? String ?? "",
            occupation: occupation?.isEmpty == false ? occupation : nil,
            photoPath: (document.get("photoPaths") as? [String])?.first(where: { !$0.isEmpty }),
            isOnline: lastActive.map { now.timeIntervalSince($0) < onlineWindow } ?? false,
            wantsToTalk: document.get("wantsToTalk") as? Bool ?? false,
            // Server-set when photo verification ships; absent means unverified.
            isVerified: document.get("isVerified") as? Bool ?? false,
            pronoun: SocialDecoding.pronoun(fromGender: document.get("gender") as? String)
        )
    }
}
#endif
