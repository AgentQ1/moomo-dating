import SwiftUI

/// The three groups of the Chat tab, in display order.
enum ChatSection: String, CaseIterable, Identifiable {
    /// The other person spoke last, or nobody has — the ball is with you.
    case yourTurn
    /// You spoke last.
    case theirTurn
    /// Conversations the local user hid. One-sided; the other person's list
    /// is unaffected.
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yourTurn: "Your turn"
        case .theirTurn: "Their turn"
        case .hidden: "Hidden"
        }
    }
}

/// The Chat tab: every conversation, grouped by whose move it is, most recent
/// first within each group. Also owns the row actions (hide, we-met, unmatch,
/// block) so every surface that shows conversations shares one code path.
@MainActor
final class ChatListModel: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    /// Collapsed section headers. Sections start expanded.
    @Published private(set) var collapsedSections: Set<ChatSection> = []
    /// Why the last row action failed, shown inline; cleared on the next one.
    @Published private(set) var actionFailure: String?

    private let service: ChatService
    private let safety: SafetyService
    private var observationTask: Task<Void, Never>?

    init(service: ChatService, safety: SafetyService) {
        self.service = service
        self.safety = safety
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

    // MARK: - Grouping

    func conversations(in section: ChatSection) -> [Conversation] {
        switch section {
        case .yourTurn: conversations.filter { !$0.isHiddenByMe && $0.turn == .yours }
        case .theirTurn: conversations.filter { !$0.isHiddenByMe && $0.turn == .theirs }
        case .hidden: conversations.filter(\.isHiddenByMe)
        }
    }

    /// The Chat tab badge: conversations waiting on the local user, hidden
    /// ones excluded — hiding something means not being nagged about it.
    var awaitingYouCount: Int { conversations(in: .yourTurn).count }

    func isCollapsed(_ section: ChatSection) -> Bool {
        collapsedSections.contains(section)
    }

    func toggleCollapsed(_ section: ChatSection) {
        if !collapsedSections.insert(section).inserted {
            collapsedSections.remove(section)
        }
    }

    // MARK: - Row actions

    func setHidden(_ hidden: Bool, _ conversation: Conversation) async {
        actionFailure = nil
        do {
            try await service.setHidden(hidden, in: conversation.id)
        } catch {
            actionFailure = failureText(error)
        }
    }

    func setWeMet(_ met: Bool, _ conversation: Conversation) async {
        actionFailure = nil
        do {
            try await service.setWeMet(met, in: conversation.id)
        } catch {
            actionFailure = failureText(error)
        }
    }

    /// Unmatch, optionally with a block on top. Unmatch first: it records the
    /// private reason; the block (which needs no existing match) then lands on
    /// an already-torn-down pair. Returns nil on success, the failure text
    /// otherwise, so the sheet can stay up and say so.
    func unmatch(
        _ conversation: Conversation,
        reason: UnmatchReason,
        alsoBlock: Bool
    ) async -> String? {
        actionFailure = nil
        do {
            try await safety.unmatch(conversation.participant, reason: reason)
            if alsoBlock {
                try await safety.block(conversation.participant)
            }
            return nil
        } catch {
            return failureText(error)
        }
    }

    private func failureText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "That didn't go through. Please try again."
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

    /// The one swiped-open row across every section.
    @State private var openRowID: String?
    @State private var unmatchTarget: Conversation?
    @State private var weMetTarget: Conversation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Chat")
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xs)

                if let failure = model.actionFailure {
                    ValidationMessage(message: failure)
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.xs)
                }

                if model.conversations.isEmpty {
                    emptyState
                        .padding(.top, Space.xxxl)
                } else {
                    sections
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.md)
                }

                Color.clear.frame(height: Size.tabBarHeight + Space.xxl)
            }
        }
        .background(Palette.canvas)
        .animation(Motion.transition, value: model.collapsedSections)
        .animation(Motion.transition, value: model.conversations)
        .sheet(item: $unmatchTarget) { conversation in
            UnmatchSheet(candidateName: conversation.participant.displayName) { reason, alsoBlock in
                await model.unmatch(conversation, reason: reason, alsoBlock: alsoBlock)
            }
        }
        .confirmationDialog(
            "Did you meet \(weMetTarget?.participant.displayName ?? "them") in person?",
            isPresented: weMetPromptShown,
            titleVisibility: .visible
        ) {
            Button("Yes, we met") {
                if let target = weMetTarget {
                    Task { await model.setWeMet(true, target) }
                }
                weMetTarget = nil
            }
            Button("Not yet", role: .cancel) { weMetTarget = nil }
        } message: {
            Text("Your answer stays private and helps keep Baybe safe.")
        }
    }

    private var weMetPromptShown: Binding<Bool> {
        Binding(
            get: { weMetTarget != nil },
            set: { if !$0 { weMetTarget = nil } }
        )
    }

    // MARK: - Sections

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ChatSection.allCases) { section in
                let items = model.conversations(in: section)
                if !items.isEmpty {
                    sectionHeader(section, count: items.count)
                    if !model.isCollapsed(section) {
                        sectionCard(items)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ section: ChatSection, count: Int) -> some View {
        Button {
            // Any swiped-open row closes before the section animates: revealed
            // action buttons must never ride along a collapse/expand.
            openRowID = nil
            withAnimation(Motion.transition) { model.toggleCollapsed(section) }
        } label: {
            HStack(spacing: Space.xs) {
                Text("\(section.title) (\(count))")
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: model.isCollapsed(section) ? "chevron.down" : "chevron.up")
                    .font(.system(size: Size.iconSmall, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.vertical, Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.title), \(count)")
        .accessibilityValue(model.isCollapsed(section) ? "Collapsed" : "Expanded")
        .accessibilityIdentifier("chat.section.\(section.rawValue)")
    }

    private func sectionCard(_ conversations: [Conversation]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(conversations.enumerated()), id: \.element.id) { index, conversation in
                SwipeActionsRow(
                    id: conversation.id,
                    actions: actions(for: conversation),
                    openRowID: $openRowID,
                    onTap: {
                        openRowID = nil
                        onOpen(conversation.id)
                    }
                ) {
                    ConversationRow(conversation: conversation)
                }
                if index < conversations.count - 1 {
                    Divider().background(Palette.separator)
                }
            }
        }
        // Filled then clipped (rather than a rounded background) so swiped
        // row content and action buttons cannot poke past the card's corners.
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .shadow(Shadows.card)
        .padding(.bottom, Space.sm)
    }

    private func actions(for conversation: Conversation) -> [SwipeRowAction] {
        [
            SwipeRowAction(title: "Unmatch", icon: "xmark", tint: Palette.coral) {
                unmatchTarget = conversation
            },
            SwipeRowAction(
                title: conversation.isHiddenByMe ? "Unhide" : "Hide",
                icon: conversation.isHiddenByMe ? "eye" : "eye.slash",
                tint: Palette.iconWell,
                foreground: Palette.ink
            ) {
                Task { await model.setHidden(!conversation.isHiddenByMe, conversation) }
            },
            SwipeRowAction(
                title: conversation.metByMe ? "Met" : "We Met",
                icon: conversation.metByMe ? "checkmark.circle.fill" : "figure.2",
                tint: Palette.blue
            ) {
                if conversation.metByMe {
                    Task { await model.setWeMet(false, conversation) }
                } else {
                    weMetTarget = conversation
                }
            }
        ]
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

/// Deliberately NOT a `Button`: the tap lives on `SwipeActionsRow` as a
/// `TapGesture`, so a swipe can never double as a tap (see the note there).
/// The button *trait* stays for VoiceOver, whose activation lands a
/// synthesized tap on the row.
private struct ConversationRow: View {
    var conversation: Conversation

    var body: some View {
        HStack(spacing: Space.sm) {
            AvatarView(
                name: conversation.participant.displayName,
                photoPath: conversation.participant.photoPath,
                size: Size.chatAvatar
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xxs) {
                    Text(conversation.participant.displayName)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if conversation.metByMe {
                        metPill
                    }
                }

                Text(preview)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("chat.row.\(conversation.participant.displayName)")
    }

    private var preview: String {
        guard let message = conversation.lastMessage else {
            return "Start the chat with \(conversation.participant.displayName) 👋"
        }
        return message.isFromMe ? "You: \(message.text)" : message.text
    }

    private var metPill: some View {
        Text("Met")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.verifiedGreenFG)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Palette.verifiedGreenBG))
            .accessibilityLabel("You met in person")
    }
}
