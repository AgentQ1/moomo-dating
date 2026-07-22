import SwiftUI

/// One conversation's thread, composer, and safety menu.
@MainActor
final class ChatDetailModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var participant: DiscoveryCandidate?
    /// The live conversation, for per-user state (hidden, met). Nil until the
    /// list snapshot arrives, and again after teardown.
    @Published private(set) var conversation: Conversation?
    @Published var draft = ""
    @Published private(set) var isSending = false
    @Published private(set) var sendFailure: String?
    /// The conversation existed and is now gone — a block (either direction)
    /// or deletion tore it down while the thread was open. Terminal: the
    /// composer is replaced by a notice, and nothing here says which side
    /// ended it.
    @Published private(set) var isUnavailable = false
    /// The LOCAL user ended it from this screen (block or unmatch) — the view
    /// pops rather than showing the "no longer available" notice, which is for
    /// teardowns that happen TO you.
    @Published private(set) var didEndMatch = false
    /// Why a menu action (hide / we met / block / unmatch) failed.
    @Published private(set) var actionFailure: String?
    @Published private(set) var didSubmitReport = false
    @Published private(set) var reportFailure: String?

    let conversationID: String
    private let service: ChatService
    private let safety: SafetyService
    private var messagesTask: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?

    init(conversationID: String, service: ChatService, safety: SafetyService) {
        self.conversationID = conversationID
        self.service = service
        self.safety = safety

        messagesTask = Task { [weak self] in
            guard let self else { return }
            for await messages in service.messagesStream(in: conversationID) {
                guard !Task.isCancelled else { return }
                self.messages = messages
                // Reading the thread is what "read" means.
                await service.markRead(conversationID)
            }
        }

        conversationTask = Task { [weak self] in
            guard let self else { return }
            var hasSeenConversation = false
            for await conversations in service.conversationsStream {
                guard !Task.isCancelled else { return }
                if let conversation = conversations.first(where: { $0.id == conversationID }) {
                    hasSeenConversation = true
                    self.conversation = conversation
                    self.participant = conversation.participant
                    // Marked read from BOTH snapshots on purpose. The message
                    // observer marks read too, but if its snapshot lands before
                    // the conversation list knows the thread (or its unread
                    // count), that write is skipped and nothing retries it —
                    // the badge stayed until the next incoming message.
                    if conversation.unreadCount > 0 {
                        await service.markRead(conversationID)
                    }
                } else if hasSeenConversation {
                    // Present before, gone now: the block cascade removed it
                    // out from under the open thread.
                    self.conversation = nil
                    self.isUnavailable = true
                }
            }
        }
    }

    deinit {
        messagesTask?.cancel()
        conversationTask?.cancel()
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        isSending = true
        defer { isSending = false }
        do {
            try await service.send(text, in: conversationID)
            draft = ""
            sendFailure = nil
        } catch {
            // Keep the draft — the user's words must survive a failed send.
            sendFailure = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't send. Please try again."
            if error as? ChatError == .unknownConversation {
                isUnavailable = true
            }
        }
    }

    // MARK: - Safety menu

    func setHidden(_ hidden: Bool) async {
        actionFailure = nil
        do {
            try await service.setHidden(hidden, in: conversationID)
        } catch {
            actionFailure = failureText(error)
        }
    }

    func setWeMet(_ met: Bool) async {
        actionFailure = nil
        do {
            try await service.setWeMet(met, in: conversationID)
        } catch {
            actionFailure = failureText(error)
        }
    }

    func block() async {
        guard let participant else { return }
        actionFailure = nil
        do {
            try await safety.block(participant)
            didEndMatch = true
        } catch {
            actionFailure = failureText(error)
        }
    }

    /// Returns nil on success, failure text otherwise — the unmatch sheet's
    /// contract.
    func unmatch(reason: UnmatchReason, alsoBlock: Bool) async -> String? {
        guard let participant else { return "Please try again." }
        do {
            try await safety.unmatch(participant, reason: reason)
            if alsoBlock {
                try await safety.block(participant)
            }
            didEndMatch = true
            return nil
        } catch {
            return failureText(error)
        }
    }

    func report(reason: ReportReason, details: String?) async {
        guard let participant else { return }
        do {
            try await safety.report(participant, reason: reason, details: details)
            didSubmitReport = true
            reportFailure = nil
        } catch {
            reportFailure = failureText(error)
        }
    }

    private func failureText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "That didn't go through. Please try again."
    }
}

struct ChatDetailView: View {
    @StateObject private var model: ChatDetailModel
    @Environment(\.dismiss) private var dismiss

    @State private var showsUnmatchSheet = false
    @State private var showsBlockConfirm = false
    @State private var showsReportSheet = false
    @State private var showsWeMetPrompt = false

    init(conversationID: String, service: ChatService, safety: SafetyService) {
        _model = StateObject(
            wrappedValue: ChatDetailModel(
                conversationID: conversationID,
                service: service,
                safety: safety
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let failure = model.actionFailure {
                ValidationMessage(message: failure)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xs)
            }
            thread
            if model.isUnavailable {
                unavailableNotice
            } else {
                composer
            }
        }
        .background(Palette.canvas)
        .navigationTitle(model.participant?.displayName ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { safetyMenu }
        .onChange(of: model.didEndMatch) {
            // The user just ended this match from the menu; the thread has
            // nothing left to show them.
            if model.didEndMatch { dismiss() }
        }
        .sheet(isPresented: $showsUnmatchSheet) {
            UnmatchSheet(candidateName: participantName) { reason, alsoBlock in
                await model.unmatch(reason: reason, alsoBlock: alsoBlock)
            }
        }
        .sheet(isPresented: $showsReportSheet) {
            ReportUserSheet(
                candidateName: participantName,
                didSubmit: model.didSubmitReport,
                failure: model.reportFailure
            ) { reason, details in
                Task { await model.report(reason: reason, details: details) }
            }
        }
        .alert("Block \(participantName)?", isPresented: $showsBlockConfirm) {
            Button("Block", role: .destructive) {
                Task { await model.block() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They won't see you in Discover or be able to contact you again. They won't be told.")
        }
        .confirmationDialog(
            "Did you meet \(participantName) in person?",
            isPresented: $showsWeMetPrompt,
            titleVisibility: .visible
        ) {
            Button("Yes, we met") { Task { await model.setWeMet(true) } }
            Button("Not yet", role: .cancel) {}
        } message: {
            Text("Your answer stays private and helps keep Moomo safe.")
        }
    }

    private var participantName: String {
        model.participant?.displayName ?? "them"
    }

    /// The overflow menu: relationship state up top, the safety exits below.
    private var safetyMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let conversation = model.conversation {
                    Button {
                        if conversation.metByMe {
                            Task { await model.setWeMet(false) }
                        } else {
                            showsWeMetPrompt = true
                        }
                    } label: {
                        Label(
                            conversation.metByMe ? "Unmark We Met" : "We Met",
                            systemImage: conversation.metByMe ? "checkmark.circle.fill" : "figure.2"
                        )
                    }

                    Button {
                        Task { await model.setHidden(!conversation.isHiddenByMe) }
                    } label: {
                        Label(
                            conversation.isHiddenByMe ? "Unhide chat" : "Hide chat",
                            systemImage: conversation.isHiddenByMe ? "eye" : "eye.slash"
                        )
                    }

                    Divider()
                }

                Button {
                    showsReportSheet = true
                } label: {
                    Label("Report…", systemImage: "flag")
                }

                Button(role: .destructive) {
                    showsBlockConfirm = true
                } label: {
                    Label("Block…", systemImage: "hand.raised")
                }

                Button(role: .destructive) {
                    showsUnmatchSheet = true
                } label: {
                    Label("Unmatch…", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Palette.ink)
            }
            .disabled(model.participant == nil || model.isUnavailable)
            .accessibilityLabel("Conversation options")
            .accessibilityIdentifier("chat.menu")
        }
    }

    /// The conversation was torn down (block, either direction — deliberately
    /// indistinguishable). No composer: nothing can be sent into it.
    private var unavailableNotice: some View {
        Label("This conversation is no longer available.", systemImage: "lock")
            .font(Typography.caption)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.md)
            .background(Palette.canvas)
            .accessibilityIdentifier("chat.unavailable")
    }

    // MARK: - Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Space.xs) {
                    if model.messages.isEmpty {
                        emptyThread
                            .padding(.top, Space.xxxl)
                    }

                    ForEach(model.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.md)
            }
            .onChange(of: model.messages.count) {
                if let last = model.messages.last {
                    withAnimation(Motion.transition) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = model.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyThread: some View {
        VStack(spacing: Space.xs) {
            if let participant = model.participant {
                AvatarView(name: participant.displayName, photoPath: participant.photoPath, size: 72)
                Text("You matched with \(participant.displayName)")
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)
            }
            Text("Say hi — you already know you both said yes.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: Space.xxs) {
            if let failure = model.sendFailure {
                ValidationMessage(message: failure)
                    .padding(.horizontal, Space.gutter)
            }

            HStack(spacing: Space.xs) {
                TextField("Message…", text: $model.draft, axis: .vertical)
                    .font(Typography.message)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1...4)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous)
                            .fill(Palette.surface)
                    )
                    .shadow(Shadows.card)
                    .accessibilityIdentifier("chat.input")
                    .onSubmit { Task { await model.send() } }

                Button {
                    Task { await model.send() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(canSend ? Palette.blue : Palette.checkboxBorder)
                            .frame(width: Size.sendButton, height: Size.sendButton)
                        if model.isSending {
                            ProgressView().progressViewStyle(.circular).tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend || model.isSending)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("chat.send")
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.xs)
        }
        .background(Palette.canvas)
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Bubble

private struct MessageBubble: View {
    var message: Message

    var body: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: Space.xxxl) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .font(Typography.message)
                    .lineSpacing(Typography.messageLineSpacing)
                    .foregroundStyle(message.isFromMe ? .white : Palette.textPrimary)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.xs + 2)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous)
                            .fill(message.isFromMe ? Palette.bubbleBlue : Palette.surface)
                    )
                    .shadow(Shadows.card)

                Text(message.sentAt.formatted(date: .omitted, time: .shortened))
                    .font(Typography.timestamp)
                    .foregroundStyle(Palette.textTertiary)
            }

            if !message.isFromMe { Spacer(minLength: Space.xxxl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            (message.isFromMe ? "You said: " : "They said: ") + message.text
        )
    }
}
