import Foundation

/// Reduces one `callInvites/{uid}` snapshot to "a ringable invite or
/// nothing", Firebase-free so the gating rules are unit-testable — the
/// Firestore listener extracts the raw fields and feeds them here, the same
/// arrangement as `MatchmakingPairingWait.matchedSessionID`.
///
/// Cache snapshots are rejected outright, for the same reason as the pairing
/// wait: terminal invites (accepted/declined/cancelled/expired) persist in
/// the document — the next ring overwrites them server-side — and Firestore
/// listeners replay the locally cached document before the first server
/// event. Trusting the replay would re-ring a call that ended minutes ago,
/// and accepting it would lose against a server that already moved on.
enum CallInviteLogic {

    /// The decoded invite, or nil when there is nothing to ring about:
    /// cache replay, terminal or missing status, past `expiresAt`, or a
    /// malformed document. Nil is a real signal — the banner comes down.
    static func invite(
        callerUid: String?,
        caller: [String: Any]?,
        mode: String?,
        status: String?,
        expiresAt: Date?,
        isFromCache: Bool,
        now: Date = Date()
    ) -> CallInvite? {
        guard
            !isFromCache,
            status == "ringing",
            let callerUid, !callerUid.isEmpty,
            let mode = mode.flatMap(CallMode.init(rawValue:)),
            let expiresAt, expiresAt > now
        else { return nil }

        return CallInvite(
            id: callerUid,
            caller: candidate(fromCallerSummary: caller, uid: callerUid),
            mode: mode,
            expiresAt: expiresAt
        )
    }

    /// The banner's `DiscoveryCandidate` from the invite's caller summary —
    /// the `ParticipantSummary` shape plus `isVerified`. Decoding tolerance
    /// mirrors `SocialDecoding.candidate(fromParticipant:uid:)` (which lives
    /// behind the Firebase import and so can't be reused here): a summary
    /// missing fields still rings, it just renders placeholders.
    ///
    /// `isOnline` is deliberately false for the same reason as there: a
    /// summary is a snapshot from fan-out time and must not claim presence —
    /// live presence belongs to Discover alone.
    static func candidate(
        fromCallerSummary data: [String: Any]?,
        uid: String
    ) -> DiscoveryCandidate {
        DiscoveryCandidate(
            id: uid,
            displayName: (data?["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Someone",
            age: data?["age"] as? Int ?? 0,
            city: data?["city"] as? String ?? "",
            photoPath: (data?["photoPath"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isOnline: false,
            wantsToTalk: false,
            isVerified: data?["isVerified"] as? Bool ?? false,
            pronoun: CandidatePronoun(genderRawValue: data?["gender"] as? String)
        )
    }
}
