import Foundation

/// An in-app notification, as shown behind the Discover bell.
///
/// These are in-app only: no APNs, no permission prompt, no delivery promise.
/// Push arrives with the real backend; this model is shaped so those land in
/// the same list.
struct AppNotification: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case wantsToTalk
        case match
        case system

        var icon: String {
            switch self {
            case .wantsToTalk: "phone.arrow.down.left.fill"
            case .match: "heart.fill"
            case .system: "sparkles"
            }
        }
    }

    var id: String
    var kind: Kind
    var title: String
    var body: String
    var sentAt: Date
    var isRead: Bool
}
