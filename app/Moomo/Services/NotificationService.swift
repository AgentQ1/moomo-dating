import Foundation

/// The in-app notification feed behind the Discover bell.
protocol NotificationService: Sendable {
    /// All notifications, newest first. Opens with the current list.
    var notificationsStream: AsyncStream<[AppNotification]> { get }

    func notifications() async -> [AppNotification]

    func markAllRead() async
}

/// In-memory notifications, seeded with the state the reference screens show
/// (an unread "wants to talk" from the featured person).
final class MockNotificationService: NotificationService, @unchecked Sendable {

    private let broadcaster: StreamBroadcaster<[AppNotification]>

    init(seed: [AppNotification] = MockNotificationService.defaultSeed()) {
        broadcaster = StreamBroadcaster(seed)
    }

    var notificationsStream: AsyncStream<[AppNotification]> { broadcaster.stream() }

    func notifications() async -> [AppNotification] { broadcaster.value }

    /// Mock-graph wiring (not a `NotificationService` requirement): stands in
    /// for the backend transactions that append to the bell feed.
    func add(_ notification: AppNotification) async {
        broadcaster.update { $0.insert(notification, at: 0) }
    }

    func markAllRead() async {
        broadcaster.update { notifications in
            for index in notifications.indices {
                notifications[index].isRead = true
            }
        }
    }

    static func defaultSeed(now: Date = Date()) -> [AppNotification] {
        [
            AppNotification(
                id: "seed-wants-to-talk",
                kind: .wantsToTalk,
                title: "Kenji wants to talk to you",
                body: "He's online now. Start a voice chat from Discover.",
                sentAt: now.addingTimeInterval(-15 * 60),
                isRead: false
            ),
            AppNotification(
                id: "seed-welcome",
                kind: .system,
                title: "Welcome to Baybe",
                body: "Three minutes, one real conversation. Be kind out there.",
                sentAt: now.addingTimeInterval(-26 * 60 * 60),
                isRead: true
            )
        ]
    }
}
