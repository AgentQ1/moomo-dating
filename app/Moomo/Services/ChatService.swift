import Foundation

/// Conversations and messages.
protocol ChatService: Sendable {
    /// Conversation list, most recent activity first. Opens with the current
    /// list; every preview/unread change re-emits.
    var conversationsStream: AsyncStream<[Conversation]> { get }

    func conversations() async -> [Conversation]

    /// One conversation's messages, oldest first. Opens with the current
    /// transcript.
    func messagesStream(in conversationID: String) -> AsyncStream<[Message]>

    func messages(in conversationID: String) async -> [Message]

    @discardableResult
    func send(_ text: String, in conversationID: String) async throws -> Message

    func markRead(_ conversationID: String) async

    /// Hides (or unhides) the conversation for the LOCAL user only. The other
    /// person's list is untouched and they are never told.
    func setHidden(_ hidden: Bool, in conversationID: String) async throws

    /// Records the LOCAL user's "we met in person" answer. Per-user state,
    /// kept for later safety check-ins and match feedback.
    func setWeMet(_ met: Bool, in conversationID: String) async throws
}

enum ChatError: LocalizedError, Equatable {
    case emptyMessage
    case unknownConversation

    var errorDescription: String? {
        switch self {
        case .emptyMessage: "Write something first."
        case .unknownConversation: "This conversation no longer exists."
        }
    }
}

/// In-memory chat. Messages persist for the app session, per the MVP contract.
///
/// The simulated peer replies once after your first message in each
/// conversation — enough to exercise receiving, unread counts, and preview
/// updates without pretending to be a person beyond that.
final class MockChatService: ChatService, @unchecked Sendable {

    private let conversationsBroadcaster = StreamBroadcaster<[Conversation]>([])

    private let lock = NSLock()
    private var messageBroadcasters: [String: StreamBroadcaster<[Message]>] = [:]
    private var repliedConversations: Set<String> = []

    private let autoReplyDelay: Duration?

    /// `autoReplyDelay: nil` disables the simulated peer (unit tests).
    init(autoReplyDelay: Duration? = .seconds(2)) {
        self.autoReplyDelay = autoReplyDelay
    }

    // MARK: - Conversations

    var conversationsStream: AsyncStream<[Conversation]> { conversationsBroadcaster.stream() }

    func conversations() async -> [Conversation] { conversationsBroadcaster.value }

    /// Mock-graph wiring (not a `ChatService` requirement): stands in for the
    /// backend transaction that mints a conversation with its match.
    func createConversation(for match: Match) async {
        let conversation = Conversation(
            id: match.conversationID,
            matchID: match.id,
            participant: match.candidate,
            createdAt: Date()
        )
        conversationsBroadcaster.update { conversations in
            guard !conversations.contains(where: { $0.id == conversation.id }) else { return }
            conversations.insert(conversation, at: 0)
        }
    }

    /// Mock-graph wiring for the block cascade the backend runs server-side.
    func removeConversations(with userID: String) async {
        let removed = conversationsBroadcaster.value.filter { $0.participant.id == userID }
        conversationsBroadcaster.update { $0.removeAll { $0.participant.id == userID } }

        lock.withLock {
            for conversation in removed {
                messageBroadcasters[conversation.id] = nil
            }
        }
    }

    func markRead(_ conversationID: String) async {
        conversationsBroadcaster.update { conversations in
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }),
                  conversations[index].unreadCount > 0 else { return }
            conversations[index].unreadCount = 0
        }
    }

    func setHidden(_ hidden: Bool, in conversationID: String) async throws {
        try updateConversation(conversationID) { $0.isHiddenByMe = hidden }
    }

    func setWeMet(_ met: Bool, in conversationID: String) async throws {
        try updateConversation(conversationID) { $0.metByMe = met }
    }

    private func updateConversation(
        _ conversationID: String,
        _ mutate: (inout Conversation) -> Void
    ) throws {
        guard conversationsBroadcaster.value.contains(where: { $0.id == conversationID }) else {
            throw ChatError.unknownConversation
        }
        conversationsBroadcaster.update { conversations in
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
            mutate(&conversations[index])
        }
    }

    // MARK: - Messages

    func messagesStream(in conversationID: String) -> AsyncStream<[Message]> {
        broadcaster(for: conversationID).stream()
    }

    func messages(in conversationID: String) async -> [Message] {
        broadcaster(for: conversationID).value
    }

    @discardableResult
    func send(_ text: String, in conversationID: String) async throws -> Message {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatError.emptyMessage }
        guard conversationsBroadcaster.value.contains(where: { $0.id == conversationID }) else {
            throw ChatError.unknownConversation
        }

        let message = Message(
            id: UUID().uuidString,
            conversationID: conversationID,
            text: trimmed,
            sentAt: Date(),
            isFromMe: true
        )
        deliver(message, unread: false)
        scheduleReplyIfFirst(in: conversationID)
        return message
    }

    /// Appends and updates the conversation preview in one step, so the list
    /// and the thread can never disagree about the last message.
    private func deliver(_ message: Message, unread: Bool) {
        broadcaster(for: message.conversationID).update { $0.append(message) }
        conversationsBroadcaster.update { conversations in
            guard let index = conversations.firstIndex(where: { $0.id == message.conversationID }) else { return }
            var conversation = conversations[index]
            conversation.lastMessage = message
            if unread { conversation.unreadCount += 1 }
            // Most recent activity first, like every messaging app.
            conversations.remove(at: index)
            conversations.insert(conversation, at: 0)
        }
    }

    // MARK: - Simulated peer

    private func scheduleReplyIfFirst(in conversationID: String) {
        guard let autoReplyDelay else { return }

        lock.lock()
        let alreadyReplied = repliedConversations.contains(conversationID)
        if !alreadyReplied { repliedConversations.insert(conversationID) }
        lock.unlock()
        guard !alreadyReplied else { return }

        Task { [weak self] in
            try? await Task.sleep(for: autoReplyDelay)
            guard let self else { return }
            // The conversation may have been removed (a block) while we slept.
            guard self.conversationsBroadcaster.value.contains(where: { $0.id == conversationID })
            else { return }

            self.deliver(
                Message(
                    id: UUID().uuidString,
                    conversationID: conversationID,
                    text: "Hey! That call went by way too fast 😄",
                    sentAt: Date(),
                    isFromMe: false
                ),
                unread: true
            )
        }
    }

    private func broadcaster(for conversationID: String) -> StreamBroadcaster<[Message]> {
        lock.lock(); defer { lock.unlock() }
        if let existing = messageBroadcasters[conversationID] { return existing }
        let created = StreamBroadcaster<[Message]>([])
        messageBroadcasters[conversationID] = created
        return created
    }
}
