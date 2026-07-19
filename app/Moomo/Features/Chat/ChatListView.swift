import SwiftUI

/// The Chat tab: every conversation, most recent first.
@MainActor
final class ChatListModel: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []

    private let service: ChatService
    private var observationTask: Task<Void, Never>?

    init(service: ChatService) {
        self.service = service
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await conversations in service.conversationsStream {
                guard !Task.isCancelled else { return }
                self.conversations = conversations
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }
}

/// A pushed conversation. Value-typed so it can live in a `NavigationPath`.
struct ChatRoute: Hashable {
    var conversationID: String
}

struct ChatListView: View {
    @ObservedObject var model: ChatListModel
    /// Pushes the conversation onto the Chat tab's navigation stack.
    var onOpen: (String) -> Void
    /// Empty-state CTA back to Discover.
    var onDiscover: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Chat")
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xs)

                if model.conversations.isEmpty {
                    emptyState
                        .padding(.top, Space.xxxl)
                } else {
                    conversationList
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.md)
                }

                Color.clear.frame(height: Size.tabBarHeight + Space.xxl)
            }
        }
        .background(Palette.canvas)
    }

    private var conversationList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.conversations.enumerated()), id: \.element.id) { index, conversation in
                ConversationRow(conversation: conversation) {
                    onOpen(conversation.id)
                }
                if index < model.conversations.count - 1 {
                    Divider().background(Palette.separator)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .shadow(Shadows.card)
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "message")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.textTertiary)

            Text("No conversations yet")
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.ink)

            Text("Match with someone after a call and your chat starts here.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xxl)

            PrimaryButton(title: "Meet someone", icon: "star.fill", action: onDiscover)
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.md)
                .accessibilityIdentifier("chat.discover")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.emptyState")
    }
}

// MARK: - Row

private struct ConversationRow: View {
    var conversation: Conversation
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                AvatarView(
                    name: conversation.participant.displayName,
                    photoPath: conversation.participant.photoPath,
                    size: Size.chatAvatar
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.participant.displayName)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)

                    Text(conversation.lastMessage.map(preview) ?? "You matched — say hi 👋")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: Space.xxs) {
                    if let last = conversation.lastMessage {
                        Text(last.sentAt.formatted(date: .omitted, time: .shortened))
                            .font(Typography.timestamp)
                            .foregroundStyle(Palette.textTertiary)
                    }
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(Typography.pill)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Palette.blue))
                            .accessibilityLabel("\(conversation.unreadCount) unread")
                    }
                }
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: Size.menuRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.row.\(conversation.participant.displayName)")
    }

    private func preview(_ message: Message) -> String {
        message.isFromMe ? "You: \(message.text)" : message.text
    }
}
