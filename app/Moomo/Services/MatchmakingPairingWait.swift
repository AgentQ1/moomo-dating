import Foundation

/// The queue-wait race, Firebase-free so its nastiest edge is testable: the
/// backend's pairing write can land in the same instant the search timeout
/// cancels the queue listener. A client that gives up right then walks away
/// from a session the server already created — and its peer starts a call
/// with nobody on the other side.
///
/// The rule: the first matched event wins; after the timeout (or a dead
/// stream) one final authoritative read decides before "no one available".
enum MatchmakingPairingWait {

    /// Reduces one queue-document snapshot to a pairing signal, or nil.
    ///
    /// Cache snapshots are rejected outright: Firestore listeners replay the
    /// locally cached document before the first server event, and the queue
    /// document keeps its last `matched` state after a call (nothing deletes
    /// it — the next join overwrites it server-side, which the cache hasn't
    /// seen yet). Trusting the replay sends a repeat search into that old,
    /// long-ended session while the real pairing lands unseen: one phone in
    /// a live call, the other on the failure screen.
    static func matchedSessionID(
        status: String?,
        sessionID: String?,
        isFromCache: Bool
    ) -> String? {
        guard !isFromCache, status == "matched" else { return nil }
        return sessionID
    }

    /// - Parameters:
    ///   - matchedSessionIDs: yields the session id whenever the queue
    ///     document reports the matched transition. Cancelled on exit.
    ///   - timeout: how long to wait for a pairing before the final check.
    ///   - finalCheck: one authoritative read of the queue document, made
    ///     only after the timeout (or a dead stream) and never after
    ///     cancellation; returns the matched session id, or nil to give up.
    static func session(
        matchedSessionIDs: AsyncStream<String>,
        timeout: Duration,
        finalCheck: @Sendable () async -> String?
    ) async throws -> String {
        let raced = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for await sessionID in matchedSessionIDs {
                    return sessionID
                }
                return nil // The stream died without a pairing.
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil // Timed out.
            }
            defer { group.cancelAll() }

            return try await group.next() ?? nil
        }
        if let raced { return raced }

        // A cancelled search is the user walking away — adopting a session
        // here would start a call nobody asked for.
        try Task.checkCancellation()

        if let sessionID = await finalCheck() {
            return sessionID
        }
        throw CallServiceError.noOneAvailable
    }
}
