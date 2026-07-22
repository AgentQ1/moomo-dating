import Foundation

/// A mutual like. Only ever created by the match service on a mutual
/// decision — nothing else may mint one, which is what keeps "match" meaning
/// *both people said yes*.
struct Match: Identifiable, Equatable, Sendable {
    var id: String
    /// The other person. The local user's identity lives in `SessionStore`.
    var candidate: DiscoveryCandidate
    var createdAt: Date
    /// Every match gets exactly one conversation, made at the same moment.
    var conversationID: String
}

/// A message thread. One per match.
struct Conversation: Identifiable, Equatable, Sendable {
    var id: String
    var matchID: String
    var participant: DiscoveryCandidate
    var createdAt: Date
    /// Denormalised preview for the conversation list, exactly as Firestore
    /// will store it — the list must not fetch every thread's messages.
    var lastMessage: Message?
    var unreadCount: Int = 0
    /// The LOCAL user's hidden flag (`hiddenBy.{uid}` in Firestore). Hiding is
    /// one-sided: the other person's list is unaffected and they are not told.
    var isHiddenByMe: Bool = false
    /// The LOCAL user marked this match as met in person (`metBy.{uid}`).
    /// Per-user, like Hinge's "We Met" — each side answers for themselves.
    var metByMe: Bool = false
}

/// Whose move it is, as the conversation list groups it.
enum ConversationTurn: Equatable, Sendable {
    /// The other person spoke last — or nobody has yet, so it's yours to open.
    case yours
    /// You spoke last; the ball is in their court.
    case theirs
}

extension Conversation {
    var turn: ConversationTurn {
        guard let lastMessage else { return .yours }
        return lastMessage.isFromMe ? .theirs : .yours
    }
}

struct Message: Identifiable, Equatable, Sendable {
    var id: String
    var conversationID: String
    var text: String
    var sentAt: Date
    /// True when the local user sent it. The Firestore implementation derives
    /// this from `senderId == auth.uid`; the mock stores it directly.
    var isFromMe: Bool
}
