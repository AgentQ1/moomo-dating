import Foundation

/// The bounded slice of a conversation an open thread renders.
///
/// The window must always hold the **newest** messages. A Firestore `limit`
/// keeps the first N documents *in query order*, so the query has to run
/// newest-first and be flipped back for display — an ascending query with a
/// limit pins the thread to its oldest N messages forever, and every message
/// past that never renders.
enum ChatHistoryWindow {
    /// How many messages an open thread renders.
    static let messageLimit = 500

    /// Display order (oldest first) from a newest-first query page.
    static func renderOrder<T>(newestFirst: [T]) -> [T] {
        newestFirst.reversed()
    }

    /// What the descending-query-plus-reverse pipeline must produce from a
    /// full ascending transcript: the newest `messageLimit`, oldest first.
    static func window<T>(overAscending messages: [T]) -> [T] {
        Array(messages.suffix(messageLimit))
    }
}
