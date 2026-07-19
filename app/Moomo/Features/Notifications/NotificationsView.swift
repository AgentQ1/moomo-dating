import SwiftUI

/// The feed behind the Discover bell.
@MainActor
final class NotificationsModel: ObservableObject {
    @Published private(set) var notifications: [AppNotification] = []

    private let service: NotificationService
    private var observationTask: Task<Void, Never>?

    init(service: NotificationService) {
        self.service = service
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await notifications in service.notificationsStream {
                guard !Task.isCancelled else { return }
                self.notifications = notifications
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    var hasUnread: Bool {
        notifications.contains { !$0.isRead }
    }

    func markAllRead() {
        Task { [service] in await service.markAllRead() }
    }
}

/// Presented as a sheet from Discover's bell.
struct NotificationsView: View {
    @ObservedObject var model: NotificationsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if model.notifications.isEmpty {
                        emptyState
                            .padding(.top, Space.xxxl)
                    } else {
                        list
                            .padding(.horizontal, Space.gutter)
                            .padding(.top, Space.md)
                    }
                }
            }
            .background(Palette.canvas)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onDisappear {
            // Read on close, not on open — the unread dots should still be
            // visible while the sheet is up.
            model.markAllRead()
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.notifications.enumerated()), id: \.element.id) { index, notification in
                NotificationRow(notification: notification)
                if index < model.notifications.count - 1 {
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
            Image(systemName: "bell")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text("Nothing yet")
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.ink)
            Text("Matches and people who want to talk show up here.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xxl)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct NotificationRow: View {
    var notification: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            ZStack {
                Circle()
                    .fill(Palette.blueTint)
                    .frame(width: Size.authIconWell, height: Size.authIconWell)
                Image(systemName: notification.kind.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(notification.kind == .match ? Palette.coral : Palette.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(Typography.rowTitleSmall)
                    .foregroundStyle(Palette.textPrimary)
                Text(notification.body)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(notification.sentAt.formatted(.relative(presentation: .named)))
                    .font(Typography.timestamp)
                    .foregroundStyle(Palette.textTertiary)
            }

            Spacer()

            if !notification.isRead {
                Circle()
                    .fill(Palette.notificationDot)
                    .frame(width: 9, height: 9)
                    .padding(.top, Space.xs)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(Space.md)
        .accessibilityElement(children: .combine)
    }
}
