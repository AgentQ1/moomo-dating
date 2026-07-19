import Foundation

#if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import FirebaseFirestore

/// Blocking and reporting against the backend.
///
/// Blocks go through the `blockUser` callable because a block must always
/// cascade (matches and conversations removed, live calls ended) — the rules
/// refuse direct client writes so a tampered client can't half-block.
/// Unblocking is a plain owner delete: it cascades nothing by design.
///
/// Reports go through `reportUser`, which validates and rate-limits.
final class FirestoreSafetyService: SafetyService, @unchecked Sendable {

    private let uid: String
    private var db: Firestore { Firestore.firestore() }

    private let blockedBroadcaster = StreamBroadcaster<[BlockedUser]>([])
    private var blockedListener: ListenerRegistration?

    /// Reports filed this session. The server copy is write-only for users,
    /// so this local list is what `reports()` can honestly return.
    private let sessionReports = StreamBroadcaster<[Report]>([])

    init(uid: String) {
        self.uid = uid

        blockedListener = blockedCollection()
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { [blockedBroadcaster] snapshot, error in
                guard let snapshot else {
                    FirestoreListeners.report(error, in: "blocks")
                    return
                }
                FirestoreListeners.recovered("blocks")
                blockedBroadcaster.send(snapshot.documents.map(Self.blockedUser(from:)))
            }
    }

    deinit {
        blockedListener?.remove()
    }

    var blockedUsersStream: AsyncStream<[BlockedUser]> { blockedBroadcaster.stream() }

    func blockedUsers() async -> [BlockedUser] {
        do {
            let snapshot = try await blockedCollection()
                .order(by: "createdAt", descending: true)
                .getDocuments()
            let blocked = snapshot.documents.map(Self.blockedUser(from:))
            blockedBroadcaster.send(blocked)
            return blocked
        } catch {
            return blockedBroadcaster.value
        }
    }

    func isBlocked(_ userID: String) async -> Bool {
        blockedBroadcaster.value.contains { $0.userID == userID }
    }

    func block(_ candidate: DiscoveryCandidate) async throws {
        _ = try await FunctionsClient.call(.blockUser, [
            "blockedUserId": candidate.id,
            "displayName": candidate.displayName
        ])
        // Reflect immediately rather than waiting a listener round trip:
        // `isBlocked` may be consulted by matchmaking in the same breath.
        blockedBroadcaster.update { blocked in
            guard !blocked.contains(where: { $0.userID == candidate.id }) else { return }
            blocked.insert(
                BlockedUser(userID: candidate.id, displayName: candidate.displayName, blockedAt: Date()),
                at: 0
            )
        }
    }

    func unblock(_ userID: String) async {
        try? await db.collection(FirestorePath.blocks).document(uid)
            .collection(FirestorePath.blocked).document(userID)
            .delete()
    }

    @discardableResult
    func report(
        _ candidate: DiscoveryCandidate,
        reason: ReportReason,
        details: String?
    ) async throws -> Report {
        let trimmedDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = [
            "reportedUserId": candidate.id,
            "reportedDisplayName": candidate.displayName,
            "reason": reason.rawValue
        ]
        if let trimmedDetails, !trimmedDetails.isEmpty {
            payload["details"] = trimmedDetails
        }

        let response = try await FunctionsClient.call(.reportUser, payload)

        let report = Report(
            id: response["reportId"] as? String ?? UUID().uuidString,
            reportedUserID: candidate.id,
            reportedDisplayName: candidate.displayName,
            reason: reason,
            details: (trimmedDetails?.isEmpty ?? true) ? nil : trimmedDetails,
            createdAt: Date()
        )
        sessionReports.update { $0.insert(report, at: 0) }
        return report
    }

    func reports() async -> [Report] { sessionReports.value }

    private func blockedCollection() -> CollectionReference {
        db.collection(FirestorePath.blocks).document(uid)
            .collection(FirestorePath.blocked)
    }

    private static func blockedUser(from document: QueryDocumentSnapshot) -> BlockedUser {
        BlockedUser(
            userID: document.documentID,
            displayName: document.get("displayName") as? String ?? "Someone",
            blockedAt: SocialDecoding.date(document.get("createdAt")) ?? Date()
        )
    }
}
#endif
