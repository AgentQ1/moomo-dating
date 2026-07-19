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
