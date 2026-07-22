import SwiftUI

/// The Matches tab: everyone who liked you back.
@MainActor
final class MatchesModel: ObservableObject {
    @Published private(set) var matches: [Match] = []
    /// Why the last card action failed, shown inline; cleared on the next one.
    @Published private(set) var actionFailure: String?
    @Published private(set) var didSubmitReport = false
    @Published private(set) var reportFailure: String?

    private let service: MatchService
    private let chat: ChatService
    private let safety: SafetyService
    private var observationTask: Task<Void, Never>?

    init(service: MatchService, chat: ChatService, safety: SafetyService) {
        self.service = service
        self.chat = chat
        self.safety = safety
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await matches in service.matchesStream {
                guard !Task.isCancelled else { return }
                self.matches = matches
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Card actions

    func markWeMet(_ match: Match) async {
        actionFailure = nil
        do {
            try await chat.setWeMet(true, in: match.conversationID)
        } catch {
            actionFailure = failureText(error)
        }
    }

    func block(_ match: Match) async {
        actionFailure = nil
        do {
            try await safety.block(match.candidate)
        } catch {
            actionFailure = failureText(error)
        }
    }

    /// Returns nil on success, failure text otherwise — the unmatch sheet's
    /// contract.
    func unmatch(_ match: Match, reason: UnmatchReason, alsoBlock: Bool) async -> String? {
        actionFailure = nil
        do {
            try await safety.unmatch(match.candidate, reason: reason)
            if alsoBlock {
                try await safety.block(match.candidate)
            }
            return nil
        } catch {
            return failureText(error)
        }
    }

    func report(_ match: Match, reason: ReportReason, details: String?) async {
        do {
            try await safety.report(match.candidate, reason: reason, details: details)
            didSubmitReport = true
            reportFailure = nil
        } catch {
            reportFailure = failureText(error)
        }
    }

    /// A fresh report sheet for a new target.
    func resetReportState() {
        didSubmitReport = false
        reportFailure = nil
    }

    private func failureText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "That didn't go through. Please try again."
    }
}

struct MatchesView: View {
    @ObservedObject var model: MatchesModel
    /// Tapping a match opens its conversation — the tab shell switches to
    /// Chat and pushes it.
    var onOpenConversation: (String) -> Void
    /// Empty-state CTA back to Discover.
    var onDiscover: () -> Void

    @State private var unmatchTarget: Match?
    @State private var blockTarget: Match?
    @State private var reportTarget: Match?
    @State private var weMetTarget: Match?

    private let columns = [
        GridItem(.flexible(), spacing: Space.tileGap),
        GridItem(.flexible(), spacing: Space.tileGap)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Matches")
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xs)

                if let failure = model.actionFailure {
                    ValidationMessage(message: failure)
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.xs)
                }

                if model.matches.isEmpty {
                    emptyState
                        .padding(.top, Space.xxxl)
                } else {
                    Text(model.matches.count == 1 ? "1 match" : "\(model.matches.count) matches")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.xxs)

                    LazyVGrid(columns: columns, spacing: Space.tileGap) {
                        ForEach(model.matches) { match in
                            MatchCard(
                                match: match,
                                action: { onOpenConversation(match.conversationID) },
                                onWeMet: { weMetTarget = match },
                                onUnmatch: { unmatchTarget = match },
                                onBlock: { blockTarget = match },
                                onReport: {
                                    model.resetReportState()
                                    reportTarget = match
                                }
                            )
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.md)
                }

                Color.clear.frame(height: Size.tabBarHeight + Space.xxl)
            }
        }
        .background(Palette.canvas)
        .animation(Motion.transition, value: model.matches)
        .sheet(item: $unmatchTarget) { match in
            UnmatchSheet(candidateName: match.candidate.displayName) { reason, alsoBlock in
                await model.unmatch(match, reason: reason, alsoBlock: alsoBlock)
            }
        }
        .sheet(item: $reportTarget) { match in
            ReportUserSheet(
                candidateName: match.candidate.displayName,
                didSubmit: model.didSubmitReport,
                failure: model.reportFailure
            ) { reason, details in
                Task { await model.report(match, reason: reason, details: details) }
            }
        }
        .alert(
            "Block \(blockTarget?.candidate.displayName ?? "them")?",
            isPresented: Binding(
                get: { blockTarget != nil },
                set: { if !$0 { blockTarget = nil } }
            )
        ) {
            Button("Block", role: .destructive) {
                if let target = blockTarget {
                    Task { await model.block(target) }
                }
                blockTarget = nil
            }
            Button("Cancel", role: .cancel) { blockTarget = nil }
        } message: {
            Text("They won't see you in Discover or be able to contact you again. They won't be told.")
        }
        .confirmationDialog(
            "Did you meet \(weMetTarget?.candidate.displayName ?? "them") in person?",
            isPresented: Binding(
                get: { weMetTarget != nil },
                set: { if !$0 { weMetTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Yes, we met") {
                if let target = weMetTarget {
                    Task { await model.markWeMet(target) }
                }
                weMetTarget = nil
            }
            Button("Not yet", role: .cancel) { weMetTarget = nil }
        } message: {
            Text("Your answer stays private and helps keep Baybe safe.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: "heart")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.textTertiary)

            Text("No matches yet")
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.ink)

            Text("When you and someone both tap Like after a call, they show up here.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xxl)

            PrimaryButton(title: "Meet someone", icon: "star.fill", action: onDiscover)
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.md)
                .accessibilityIdentifier("matches.discover")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("matches.emptyState")
    }
}

// MARK: - Card

/// One match: photo placeholder, name, age, city. Tapping opens the chat;
/// the corner menu holds the relationship and safety actions.
private struct MatchCard: View {
    var match: Match
    var action: () -> Void
    var onWeMet: () -> Void
    var onUnmatch: () -> Void
    var onBlock: () -> Void
    var onReport: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                AvatarView(name: match.candidate.displayName, photoPath: match.candidate.photoPath, size: 96)
                    .overlay(alignment: .bottomTrailing) {
                        if match.candidate.isOnline {
                            Circle()
                                .fill(Palette.online)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().stroke(.white, lineWidth: 3))
                        }
                    }
                    .padding(.top, Space.md)

                Text("\(match.candidate.displayName), \(match.candidate.age)")
                    .font(Typography.rowTitleSmall)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .padding(.top, Space.sm)

                Text(match.candidate.city)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .padding(.top, 2)

                Label("Chat", systemImage: "message.fill")
                    .font(Typography.pill)
                    .foregroundStyle(Palette.blue)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Palette.blueTint))
                    .padding(.top, Space.sm)
                    .padding(.bottom, Space.md)
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
            .shadow(Shadows.card)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(match.candidate.displayName), \(match.candidate.age), \(match.candidate.city). Open chat."
        )
        .accessibilityIdentifier("matches.card.\(match.candidate.displayName)")
        // After the card's a11y combine, so the menu stays its own element.
        .overlay(alignment: .topTrailing) { overflowMenu }
    }

    private var overflowMenu: some View {
        Menu {
            Button(action: onWeMet) {
                Label("We Met", systemImage: "figure.2")
            }
            Button(action: onReport) {
                Label("Report…", systemImage: "flag")
            }
            Divider()
            Button(role: .destructive, action: onBlock) {
                Label("Block…", systemImage: "hand.raised")
            }
            Button(role: .destructive, action: onUnmatch) {
                Label("Unmatch…", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Size.iconSmall, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: Size.minTapTarget - Space.xs, height: Size.minTapTarget - Space.xs)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Options for \(match.candidate.displayName)")
        .accessibilityIdentifier("matches.menu.\(match.candidate.displayName)")
    }
}
