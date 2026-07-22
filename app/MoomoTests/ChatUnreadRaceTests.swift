import XCTest
@testable import Moomo

/// The mark-read race: opening a thread must clear the unread badge even when
/// the MESSAGE snapshot lands before the conversation list knows the thread's
/// unread count — the old code only marked read from the message stream, and
/// nothing retried once the conversation arrived.
@MainActor
final class ChatUnreadRaceTests: XCTestCase {

    /// A chat service whose two streams the test scripts independently.
    private final class ScriptedChatService: ChatService, @unchecked Sendable {
        let conversationsBroadcaster = StreamBroadcaster<[Conversation]>([])
        let messagesBroadcaster = StreamBroadcaster<[Message]>([])

        var conversationsStream: AsyncStream<[Conversation]> { conversationsBroadcaster.stream() }
        func conversations() async -> [Conversation] { conversationsBroadcaster.value }
        func messagesStream(in conversationID: String) -> AsyncStream<[Message]> {
            messagesBroadcaster.stream()
        }
        func messages(in conversationID: String) async -> [Message] { messagesBroadcaster.value }

        @discardableResult
        func send(_ text: String, in conversationID: String) async throws -> Message {
            throw ChatError.unknownConversation
        }

        func markRead(_ conversationID: String) async {
            conversationsBroadcaster.update { conversations in
                guard let index = conversations.firstIndex(where: { $0.id == conversationID })
                else { return }
                conversations[index].unreadCount = 0
            }
        }

        func setHidden(_ hidden: Bool, in conversationID: String) async throws {}
        func setWeMet(_ met: Bool, in conversationID: String) async throws {}
    }

    private let peer = DiscoveryCandidate(
        id: "u-peer", displayName: "Kenji", age: 26, city: "Chicago",
        photoPath: nil, isOnline: true, wantsToTalk: false, pronoun: .he
    )

    func testUnreadClearsWhenTheConversationSnapshotArrivesAfterTheMessages() async {
        let service = ScriptedChatService()
        let model = ChatDetailModel(
            conversationID: "c1", service: service, safety: MockSafetyService()
        )

        // Messages land first — before the conversation list knows the thread.
        service.messagesBroadcaster.send([
            Message(id: "m1", conversationID: "c1", text: "hey", sentAt: Date(), isFromMe: false)
        ])
        try? await Task.sleep(for: .milliseconds(100))

        // Now the conversation snapshot arrives carrying the unread count.
        // No further message snapshot will come — the conversation observer
        // alone must clear it.
        service.conversationsBroadcaster.send([
            Conversation(
                id: "c1", matchID: "m", participant: peer,
                createdAt: Date(), lastMessage: nil, unreadCount: 1
            )
        ])
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            service.conversationsBroadcaster.value.first?.unreadCount, 0,
            "Opening the thread must clear unread regardless of snapshot order"
        )
        XCTAssertEqual(model.participant?.id, peer.id)
    }
}
