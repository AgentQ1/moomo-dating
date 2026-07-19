import Foundation

#if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
import FirebaseFirestore

/// The bell feed from `users/{uid}/notifications` — written by the backend
/// (match transactions, admin announcements), read and marked-read here.
final class FirestoreNotificationService: NotificationService, @unchecked Sendable {

    private let uid: String
    private var db: Firestore { Firestore.firestore() }

    private let broadcaster = StreamBroadcaster<[AppNotification]>([])
    private var listener: ListenerRegistration?

    init(uid: String) {
        self.uid = uid

        listener = db.collection(FirestorePath.users).document(uid)
            .collection(FirestorePath.notifications)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)
            .addSnapshotListener { [broadcaster] snapshot, error in
                guard let snapshot else {
                    FirestoreListeners.report(error, in: "notifications")
                    return
                }
                FirestoreListeners.recovered("notifications")
                broadcaster.send(snapshot.documents.map(Self.notification(from:)))
            }
    }

    deinit {
        listener?.remove()
    }

    var notificationsStream: AsyncStream<[AppNotification]> { broadcaster.stream() }

    func notifications() async -> [AppNotification] { broadcaster.value }

    func markAllRead() async {
        let unread = broadcaster.value.filter { !$0.isRead }
        guard !unread.isEmpty else { return }

        let batch = db.batch()
        let collection = db.collection(FirestorePath.users).document(uid)
            .collection(FirestorePath.notifications)
        for notification in unread {
            batch.updateData(["isRead": true], forDocument: collection.document(notification.id))
        }
        try? await batch.commit()
    }

    private static func notification(from document: QueryDocumentSnapshot) -> AppNotification {
        AppNotification(
            id: document.documentID,
            kind: (document.get("kind") as? String).flatMap(AppNotification.Kind.init(rawValue:)) ?? .system,
            title: document.get("title") as? String ?? "",
            body: document.get("body") as? String ?? "",
            sentAt: SocialDecoding.date(document.get("createdAt")) ?? Date(),
            isRead: document.get("isRead") as? Bool ?? true
        )
    }
}
#endif
