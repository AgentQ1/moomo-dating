import SwiftUI

/// The Matches tab: everyone who liked you back.
@MainActor
final class MatchesModel: ObservableObject {
    @Published private(set) var matches: [Match] = []

    private let service: MatchService
    private var observationTask: Task<Void, Never>?

    init(service: MatchService) {
        self.service = service
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
}

struct MatchesView: View {
    @ObservedObject var model: MatchesModel
    /// Tapping a match opens its conversation — the tab shell switches to
    /// Chat and pushes it.
    var onOpenConversation: (String) -> Void
    /// Empty-state CTA back to Discover.
    var onDiscover: () -> Void

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
                            MatchCard(match: match) {
                                onOpenConversation(match.conversationID)
                            }
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.md)
                }

                Color.clear.frame(height: Size.tabBarHeight + Space.xxl)
            }
        }
        .background(Palette.canvas)
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

/// One match: photo placeholder, name, age, city. Tapping opens the chat.
private struct MatchCard: View {
    var match: Match
    var action: () -> Void

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
    }
}
