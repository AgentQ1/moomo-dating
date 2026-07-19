import Foundation

#if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import FirebaseFirestore

/// Real matchmaking and call history against the Cloud Functions backend.
///
/// `findCandidate` joins the server queue; either the callable pairs us
/// immediately with someone already waiting, or we listen to our own
/// `matchmakingQueue/{uid}` document until the backend writes a sessionId —
/// or the search times out and we leave the queue. Nothing is simulated:
/// if nobody is waiting, there is honestly no one to talk to.
///
/// History is the server-written `users/{uid}/callHistory` projection.
/// `record()` maps to the `endCallSession` callable; `setOutcome` is a no-op
/// because outcomes are derived server-side from decisions and blocks.
final class FirestoreCallService: CallService, @unchecked Sendable {

    /// How long a search waits for a partner before giving up. Long enough
    /// for a real human to join; short enough that "no one's around" is told
    /// honestly rather than spinning forever. Must stay under the backend's
    /// `QUEUE_ENTRY_TTL_MS` (40s): entries older than that are treated as
    /// dead clients and are never paired.
    static let searchTimeout: Duration = .seconds(30)

    private let uid: String
    private var db: Firestore { Firestore.firestore() }

    private let historyBroadcaster = StreamBroadcaster<[CallRecord]>([])
    private var historyListener: ListenerRegistration?

    private let lock = NSLock()
    private var pendingSession: PendingSession?

    /// What `findCandidate` learned, held for the immediately-following
    /// `connect`. The two-step protocol shape exists for the flow's UI states;
    /// the server session already exists by the time we know the candidate.
    private struct PendingSession {
        let id: String
        let candidate: DiscoveryCandidate
        let mode: CallMode
        let startedAt: Date
        let maxDuration: TimeInterval
    }

    init(uid: String) {
        self.uid = uid

        historyListener = db.collection(FirestorePath.users).document(uid)
            .collection(FirestorePath.callHistory)
            .order(by: "startedAt", descending: true)
            .limit(to: 50)
            .addSnapshotListener { [historyBroadcaster] snapshot, error in
                guard let snapshot else {
                    FirestoreListeners.report(error, in: "callHistory")
                    return
                }
                FirestoreListeners.recovered("callHistory")
                historyBroadcaster.send(snapshot.documents.map(Self.record(from:)))
            }
    }

    deinit {
        historyListener?.remove()
    }

    // MARK: - Matchmaking

    func findCandidate(
        mode: CallMode,
        preferring preferred: DiscoveryCandidate?
    ) async throws -> DiscoveryCandidate {
        var payload: [String: Any] = ["mode": mode.rawValue]
        if let preferred {
            payload["preferredPeerId"] = preferred.id
        }

        let response = try await FunctionsClient.call(.joinMatchmakingQueue, payload)

        if response["status"] as? String == "matched",
           let session = response["session"] as? [String: Any] {
            return try storePending(fromCallablePayload: session, mode: mode)
        }

        // Waiting. Watch our own queue entry for the backend's pairing write.
        do {
            let sessionID = try await waitForPairing()
            let document = try await db.collection(FirestorePath.callSessions)
                .document(sessionID).getDocument()
            return try storePending(fromSessionDocument: document, mode: mode)
        } catch {
            // Timed out or cancelled: get out of the queue before surfacing
            // the failure, so a dead entry can't pair us into a call we
            // already walked away from. An unstructured task so cancellation
            // can't kill the cleanup — but awaited, so a fast retry's fresh
            // queue entry can't be deleted by this search's leave landing late.
            _ = await Task { try? await FunctionsClient.call(.leaveMatchmakingQueue) }.value
            throw error
        }
    }

    private func waitForPairing() async throws -> String {
        let queueDocument = db.collection(FirestorePath.matchmakingQueue).document(uid)

        // The queue document's snapshots, reduced to matched transitions.
        // Cache replays are filtered out (see `matchedSessionID`) — only the
        // server may tell us we were paired.
        let matchedSessionIDs = AsyncStream<String> { continuation in
            let task = Task {
                for await snapshot in queueDocument.snapshotStream() {
                    if let sessionID = MatchmakingPairingWait.matchedSessionID(
                        status: snapshot.get("status") as? String,
                        sessionID: snapshot.get("sessionId") as? String,
                        isFromCache: snapshot.metadata.isFromCache
                    ) {
                        continuation.yield(sessionID)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return try await MatchmakingPairingWait.session(
            matchedSessionIDs: matchedSessionIDs,
            timeout: Self.searchTimeout
        ) {
            // The pairing transaction can commit in the same instant the
            // timeout cancels the listener; abandoning the search on the
            // timeout alone would leave the peer in a call with nobody.
            // Server read on purpose — the cache would just echo the stale
            // "waiting" the listener already showed us.
            guard let snapshot = try? await queueDocument.getDocument(source: .server),
                  snapshot.get("status") as? String == "matched"
            else { return nil }
            return snapshot.get("sessionId") as? String
        }
    }

    func connect(to candidate: DiscoveryCandidate, mode: CallMode) async throws -> CallSession {
        let pending = lock.withLock {
            let value = pendingSession
            pendingSession = nil
            return value
        }

        guard let pending, pending.candidate.id == candidate.id else {
            throw CallServiceError.sessionNotReady
        }
        return CallSession(
            id: pending.id,
            candidate: pending.candidate,
            mode: pending.mode,
            startedAt: pending.startedAt,
            maxDuration: pending.maxDuration
        )
    }

    private func storePending(
        fromCallablePayload payload: [String: Any],
        mode: CallMode
    ) throws -> DiscoveryCandidate {
        guard
            let sessionID = payload["sessionId"] as? String,
            let participants = payload["participants"] as? [String: [String: Any]],
            let peerID = participants.keys.first(where: { $0 != uid })
        else {
            throw CallServiceError.sessionNotReady
        }
        let startedAtMillis = (payload["startedAtMillis"] as? Double) ?? Date().timeIntervalSince1970 * 1000
        let maxDuration = (payload["maxDurationSeconds"] as? Double) ?? CallSession.speedCallDuration

        return storePending(PendingSession(
            id: sessionID,
            candidate: SocialDecoding.candidate(fromParticipant: participants[peerID], uid: peerID),
            mode: mode,
            startedAt: Date(timeIntervalSince1970: startedAtMillis / 1000),
            maxDuration: maxDuration
        ))
    }

    private func storePending(
        fromSessionDocument document: DocumentSnapshot,
        mode: CallMode
    ) throws -> DiscoveryCandidate {
        guard
            document.exists,
            // A session that is no longer active is an old pairing; a stale
            // queue signal must never connect us into an ended call.
            document.get("status") as? String == "active",
            let participantIds = document.get("participantIds") as? [String],
            let peerID = SocialDecoding.peerID(in: participantIds, me: uid)
        else {
            throw CallServiceError.sessionNotReady
        }
        let participants = document.get("participants") as? [String: [String: Any]]

        return storePending(PendingSession(
            id: document.documentID,
            candidate: SocialDecoding.candidate(fromParticipant: participants?[peerID], uid: peerID),
            mode: mode,
            startedAt: SocialDecoding.date(document.get("startedAt")) ?? Date(),
            maxDuration: document.get("maxDurationSeconds") as? Double ?? CallSession.speedCallDuration
        ))
    }

    private func storePending(_ pending: PendingSession) -> DiscoveryCandidate {
        lock.lock()
        pendingSession = pending
        lock.unlock()
        return pending.candidate
    }

    // MARK: - Peer end

    /// Watches the session document for the server-side end written by the
    /// peer's `endCallSession` (or the block cascade). Our own end is filtered
    /// out by `endedBy` — the flow already handled it locally. Always plain
    /// `.ended`: the session document never says "blocked", by design.
    func endEvents(for sessionID: String) -> AsyncStream<CallEndReason> {
        let document = db.collection(FirestorePath.callSessions).document(sessionID)
        let uid = uid
        return AsyncStream { continuation in
            let task = Task {
                for await snapshot in document.snapshotStream() {
                    guard
                        snapshot.get("status") as? String == "ended",
                        snapshot.get("endedBy") as? String != uid
                    else { continue }
                    continuation.yield(.ended)
                    break
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - History

    var historyStream: AsyncStream<[CallRecord]> { historyBroadcaster.stream() }

    func history() async -> [CallRecord] { historyBroadcaster.value }

    /// The flow "records" a finished call by ending the server session; the
    /// backend writes both participants' history projections and the listener
    /// above delivers ours. The record's id IS the session id.
    func record(_ record: CallRecord) async {
        _ = try? await FunctionsClient.call(.endCallSession, [
            "sessionId": record.id,
            "reason": record.endReason.rawValue
        ])
    }

    /// Outcomes are server-derived (from decisions and blocks) and arrive via
    /// the history listener; there is nothing for the client to stamp.
    func setOutcome(_ outcome: CallOutcome, forRecord id: String) async {}

    private static func record(from document: QueryDocumentSnapshot) -> CallRecord {
        let peer = document.get("peer") as? [String: Any]
        let peerID = peer?["uid"] as? String ?? "unknown"
        return CallRecord(
            id: document.documentID,
            candidate: SocialDecoding.candidate(fromParticipant: peer, uid: peerID),
            mode: (document.get("mode") as? String).flatMap(CallMode.init(rawValue:)) ?? .voice,
            startedAt: SocialDecoding.date(document.get("startedAt")) ?? Date(),
            duration: document.get("durationSeconds") as? Double ?? 0,
            endReason: (document.get("endReason") as? String).flatMap(CallEndReason.init(rawValue:)) ?? .ended,
            outcome: (document.get("outcome") as? String).flatMap(CallOutcome.init(rawValue:)) ?? .undecided
        )
    }
}
#endif
