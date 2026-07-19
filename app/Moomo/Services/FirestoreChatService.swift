import Foundation

#if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import FirebaseFirestore

/// Firestore-backed conversations and messages.
///
/// Conversations are server-created (with the match) and server-maintained
/// (an `onMessageCreated` trigger keeps previews and unread counts honest).
/// The client does exactly two writes here, both rules-enforced:
///  - append a message to a thread it belongs to, as itself;
///  - zero its own unread counter (`markRead`).
///
/// One persistent listener feeds the conversation list; each opened thread
/// gets its own listener, kept for the session and removed with the service.
final class FirestoreChatService: ChatService, @unchecked Sendable {

    private let uid: String
    private var db: Firestore { Firestore.firestore() }

    private let conversationsBroadcaster = StreamBroadcaster<[Conversation]>([])
    private var conversationsListener: ListenerRegistration?

    private let lock = NSLock()
    private var messageBroadcasters: [String: StreamBroadcaster<[Message]>] = [:]
    private var messageListeners: [String: ListenerRegistration] = [:]

    init(uid: String) {
        self.uid = uid

        conversationsListener = db.collection(FirestorePath.conversations)
            .whereField("participantIds", arrayContains: uid)
            .order(by: "lastMessageAt", descending: true)
            .limit(to: 100)
            .addSnapshotListener { [conversationsBroadcaster, uid] snapshot, error in
                guard let snapshot else {
                    FirestoreListeners.report(error, in: "chat.conversations")
                    return
                }
                FirestoreListeners.recovered("chat.conversations")
                conversationsBroadcaster.send(snapshot.documents.compactMap {
                    Self.conversation(from: $0, me: uid)
                })
            }
    }

    deinit {
        conversationsListener?.remove()
        lock.lock()
        let listeners = messageListeners.values
        lock.unlock()
        listeners.forEach { $0.remove() }
    }

    // MARK: - Conversations

    var conversationsStream: AsyncStream<[Conversation]> { conversationsBroadcaster.stream() }

    func conversations() async -> [Conversation] { conversationsBroadcaster.value }

    func markRead(_ conversationID: String) async {
        // Only write when there is something to clear — this runs on every
        // thread snapshot, and a blind write per received message would double
        // the message volume in writes.
        guard let conversation = conversationsBroadcaster.value.first(where: { $0.id == conversationID }),
              conversation.unreadCount > 0 else { return }

        try? await db.collection(FirestorePath.conversations).document(conversationID)
            .updateData(["unreadCounts.\(uid)": 0])
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

        let reference = db.collection(FirestorePath.conversations).document(conversationID)
            .collection(FirestorePath.messages).document()
        do {
            // Exactly the rules-whitelisted shape. `serverTimestamp` satisfies
            // the `sentAt == request.time` check.
            try await reference.setData([
                "senderId": uid,
                "text": trimmed,
                "sentAt": FieldValue.serverTimestamp()
            ])
        } catch {
            // Permission denied here means the conversation is gone or was
            // never ours — including the blocked case, where the cascade
            // deleted it. Same user-facing truth either way.
            if (error as NSError).domain == FirestoreErrorDomain,
               (error as NSError).code == FirestoreErrorCode.permissionDenied.rawValue {
                throw ChatError.unknownConversation
            }
            throw error
        }

        return Message(
            id: reference.documentID,
            conversationID: conversationID,
            text: trimmed,
            sentAt: Date(),
            isFromMe: true
        )
    }

    private func broadcaster(for conversationID: String) -> StreamBroadcaster<[Message]> {
        lock.lock(); defer { lock.unlock() }
        if let existing = messageBroadcasters[conversationID] { return existing }

        let created = StreamBroadcaster<[Message]>([])
        messageBroadcasters[conversationID] = created

        // Newest-first so the limit keeps the newest page — ascending with a
        // limit would freeze the thread at its oldest 500 messages forever.
        messageListeners[conversationID] = db.collection(FirestorePath.conversations)
            .document(conversationID)
            .collection(FirestorePath.messages)
            .order(by: "sentAt", descending: true)
            .limit(to: ChatHistoryWindow.messageLimit)
            .addSnapshotListener { [uid] snapshot, error in
                guard let snapshot else {
                    FirestoreListeners.report(error, in: "chat.messages")
                    return
                }
                FirestoreListeners.recovered("chat.messages")
                created.send(ChatHistoryWindow.renderOrder(
                    newestFirst: snapshot.documents.map {
                        Self.message(from: $0, in: conversationID, me: uid)
                    }
                ))
            }
        return created
    }

    // MARK: - Decoding

    private static func conversation(
        from document: QueryDocumentSnapshot,
        me: String
    ) -> Conversation? {
        guard
            let participantIds = document.get("participantIds") as? [String],
            let peerID = SocialDecoding.peerID(in: participantIds, me: me)
        else { return nil }

        let participants = document.get("participants") as? [String: [String: Any]]
        let unreadCounts = document.get("unreadCounts") as? [String: Int]

        var lastMessage: Message?
        if let preview = document.get("lastMessage") as? [String: Any],
           let text = preview["text"] as? String,
           let senderID = preview["senderId"] as? String {
            lastMessage = Message(
                id: "\(document.documentID)-preview",
                conversationID: document.documentID,
                text: text,
                sentAt: SocialDecoding.date(preview["sentAt"]) ?? Date(),
                isFromMe: senderID == me
            )
        }

        return Conversation(
            id: document.documentID,
            matchID: document.get("matchId") as? String ?? "",
            participant: SocialDecoding.candidate(fromParticipant: participants?[peerID], uid: peerID),
            createdAt: SocialDecoding.date(document.get("createdAt")) ?? Date(),
            lastMessage: lastMessage,
            unreadCount: unreadCounts?[me] ?? 0
        )
    }

    private static func message(
        from document: QueryDocumentSnapshot,
        in conversationID: String,
        me: String
    ) -> Message {
        // `.estimate` so our own just-sent message (whose server timestamp is
        // still pending) sorts and renders instead of vanishing for a beat.
        let data = document.data(with: .estimate)
        return Message(
            id: document.documentID,
            conversationID: conversationID,
            text: data["text"] as? String ?? "",
            sentAt: SocialDecoding.date(data["sentAt"]) ?? Date(),
            isFromMe: (data["senderId"] as? String) == me
        )
    }
}
#endif
