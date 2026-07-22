import Foundation

/// Blocking and reporting.
///
/// The contract every implementation must keep: blocking is immediate,
/// one-sided, and silent — the blocked person is removed from every surface
/// and never told. Reports are write-only from the client; only moderation
/// reads them (mirrored by the Firestore rules).
protocol SafetyService: Sendable {
    /// Everyone the local user has blocked, newest first.
    var blockedUsersStream: AsyncStream<[BlockedUser]> { get }

    func blockedUsers() async -> [BlockedUser]

    func isBlocked(_ userID: String) async -> Bool

    /// Throws when the block could not be recorded — the caller must tell the
    /// user rather than let them believe someone is gone who isn't.
    func block(_ candidate: DiscoveryCandidate) async throws

    func unblock(_ userID: String) async

    /// Throws when the report could not be filed — a "report received"
    /// confirmation for a report that never arrived would be a lie.
    @discardableResult
    func report(_ candidate: DiscoveryCandidate, reason: ReportReason, details: String?) async throws -> Report

    /// Reports submitted this session. Exposed for tests and the moderation
    /// hand-off; not shown in the UI (reports are write-only for users).
    func reports() async -> [Report]

    /// Ends the match with someone: the match and its conversation are removed
    /// for both people, and the reason is stored privately — the other person
    /// only sees the match disappear. Unlike a block, an unmatch does not
    /// prevent meeting again through a future call.
    ///
    /// Throws when the unmatch could not be recorded — the row must not
    /// vanish from the list if the match still exists.
    func unmatch(_ candidate: DiscoveryCandidate, reason: UnmatchReason) async throws
}

/// A recorded unmatch. Mock-only bookkeeping (the backend keeps the real,
/// server-owned copy) so tests can prove the reason was stored.
struct UnmatchRecord: Equatable, Sendable {
    var userID: String
    var reason: UnmatchReason
    var unmatchedAt: Date
}

/// In-memory safety state.
final class MockSafetyService: SafetyService, @unchecked Sendable {

    private let blockedBroadcaster = StreamBroadcaster<[BlockedUser]>([])
    private let reportsBroadcaster = StreamBroadcaster<[Report]>([])
    private let unmatchesBroadcaster = StreamBroadcaster<[UnmatchRecord]>([])

    /// The ripple a block causes elsewhere (drop matches, drop conversations),
    /// wired by `AppServices` the way backend triggers would be.
    private let onBlock: @Sendable (String) async -> Void
    /// The unmatch cascade: same teardown as a block, without the block.
    private let onUnmatch: @Sendable (String) async -> Void

    init(
        onBlock: @escaping @Sendable (String) async -> Void = { _ in },
        onUnmatch: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.onBlock = onBlock
        self.onUnmatch = onUnmatch
    }

    var blockedUsersStream: AsyncStream<[BlockedUser]> { blockedBroadcaster.stream() }

    func blockedUsers() async -> [BlockedUser] { blockedBroadcaster.value }

    func isBlocked(_ userID: String) async -> Bool {
        blockedBroadcaster.value.contains { $0.userID == userID }
    }

    func block(_ candidate: DiscoveryCandidate) async throws {
        let alreadyBlocked = blockedBroadcaster.value.contains { $0.userID == candidate.id }
        guard !alreadyBlocked else { return }

        blockedBroadcaster.update {
            $0.insert(
                BlockedUser(userID: candidate.id, displayName: candidate.displayName, blockedAt: Date()),
                at: 0
            )
        }
        await onBlock(candidate.id)
    }

    func unblock(_ userID: String) async {
        blockedBroadcaster.update { $0.removeAll { $0.userID == userID } }
    }

    @discardableResult
    func report(
        _ candidate: DiscoveryCandidate,
        reason: ReportReason,
        details: String?
    ) async throws -> Report {
        let trimmedDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        let report = Report(
            id: UUID().uuidString,
            reportedUserID: candidate.id,
            reportedDisplayName: candidate.displayName,
            reason: reason,
            details: (trimmedDetails?.isEmpty ?? true) ? nil : trimmedDetails,
            createdAt: Date()
        )
        reportsBroadcaster.update { $0.insert(report, at: 0) }
        return report
    }

    func reports() async -> [Report] { reportsBroadcaster.value }

    func unmatch(_ candidate: DiscoveryCandidate, reason: UnmatchReason) async throws {
        unmatchesBroadcaster.update {
            $0.insert(
                UnmatchRecord(userID: candidate.id, reason: reason, unmatchedAt: Date()),
                at: 0
            )
        }
        await onUnmatch(candidate.id)
    }

    /// Unmatches recorded this session, for tests — the real store is
    /// server-owned and never readable from the client.
    func unmatches() async -> [UnmatchRecord] { unmatchesBroadcaster.value }
}
