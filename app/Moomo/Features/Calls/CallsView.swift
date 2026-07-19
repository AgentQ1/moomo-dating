import SwiftUI

/// The Calls tab: the running call (if any) and finished-call history.
@MainActor
final class CallsModel: ObservableObject {
    @Published private(set) var records: [CallRecord] = []

    private let calls: CallService
    private var observationTask: Task<Void, Never>?

    init(calls: CallService) {
        self.calls = calls
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await records in calls.historyStream {
                guard !Task.isCancelled else { return }
                self.records = records
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }
}

struct CallsView: View {
    @ObservedObject var model: CallsModel
    @ObservedObject var coordinator: CallCoordinator
    /// Empty-state CTA: the tab shell switches to Discover.
    var onStartMatching: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Calls")
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.xs)

                if coordinator.hasActiveCall {
                    activeCallCard
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.md)
                }

                if model.records.isEmpty && !coordinator.hasActiveCall {
                    emptyState
                        .padding(.top, Space.xxxl)
                } else if !model.records.isEmpty {
                    Text("RECENT")
                        .font(Typography.sectionLabel)
                        .tracking(Typography.sectionTracking)
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, Space.gutter)
                        .padding(.top, Space.xl)
                        .padding(.bottom, Space.sm)

                    recentList
                        .padding(.horizontal, Space.gutter)
                }

                Color.clear.frame(height: Size.tabBarHeight + Space.xxl)
            }
        }
        .background(Palette.canvas)
    }

    // MARK: - Active call

    private var activeCallCard: some View {
        Button {
            coordinator.resume()
        } label: {
            HStack(spacing: Space.sm) {
                if let candidate = coordinator.flow?.candidate {
                    AvatarView(name: candidate.displayName, photoPath: candidate.photoPath, size: Size.chatAvatar)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Call in progress")
                        .font(Typography.rowTitleSmall)
                        .foregroundStyle(.white)
                    if let candidate = coordinator.flow?.candidate {
                        Text("with \(candidate.displayName) — tap to return")
                            .font(Typography.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                Spacer()

                Image(systemName: "phone.fill")
                    .font(.system(size: Size.iconMedium))
                    .foregroundStyle(.white)
            }
            .padding(Space.md)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.online)
            )
            .shadow(Shadows.card)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to your call in progress")
        .accessibilityIdentifier("calls.activeCall")
    }

    // MARK: - History

    private var recentList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.records.enumerated()), id: \.element.id) { index, record in
                CallHistoryRow(record: record)
                if index < model.records.count - 1 {
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
            Image(systemName: "phone")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.textTertiary)

            Text("No calls yet")
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.ink)

            Text("Your speed calls show up here. Start one from Discover.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xxl)

            PrimaryButton(title: "Start matching", icon: "phone.fill", action: onStartMatching)
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.md)
                .accessibilityIdentifier("calls.startMatching")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calls.emptyState")
    }
}

// MARK: - Row

private struct CallHistoryRow: View {
    var record: CallRecord

    var body: some View {
        HStack(spacing: Space.sm) {
            AvatarView(name: record.candidate.displayName, photoPath: record.candidate.photoPath, size: Size.chatAvatar)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.candidate.displayName)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)

                HStack(spacing: Space.xxs) {
                    Image(systemName: record.mode.icon)
                        .font(.system(size: 11))
                    Text("\(formattedDuration) · \(record.startedAt.formatted(.relative(presentation: .named)))")
                        .font(Typography.caption)
                }
                .foregroundStyle(Palette.textSecondary)
            }

            Spacer()

            outcomeBadge
        }
        .padding(.horizontal, Space.md)
        .frame(minHeight: Size.menuRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calls.row.\(record.candidate.displayName)")
    }

    @ViewBuilder
    private var outcomeBadge: some View {
        switch record.outcome {
        case .matched:
            badge("Matched", foreground: Palette.verifiedGreenFG, background: Palette.verifiedGreenBG)
        case .liked:
            badge("Liked", foreground: Palette.coral, background: Palette.peachTint)
        case .passed:
            badge("Passed", foreground: Palette.textSecondary, background: Palette.iconWell)
        case .blocked:
            badge("Blocked", foreground: Palette.textSecondary, background: Palette.iconWell)
        case .undecided:
            EmptyView()
        }
    }

    private func badge(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(Typography.pill)
            .foregroundStyle(foreground)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 4)
            .background(Capsule().fill(background))
    }

    private var formattedDuration: String {
        let seconds = Int(record.duration.rounded())
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
