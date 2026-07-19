import Foundation

/// Someone the local user has blocked. Blocking removes them from Discover,
/// matchmaking, matches, and chat, and they are never told.
struct BlockedUser: Identifiable, Equatable, Sendable {
    var id: String { userID }
    var userID: String
    /// Kept so the blocked-users list can name them after their profile is
    /// gone from every other surface.
    var displayName: String
    var blockedAt: Date
}

/// Why a user is being reported. Raw values are the wire format — they must
/// match the `reason` whitelist in `backend/firestore.rules`.
enum ReportReason: String, CaseIterable, Identifiable, Sendable {
    case harassment
    case inappropriateContent = "inappropriate_content"
    case spam
    case underage
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .harassment: "Harassment or bullying"
        case .inappropriateContent: "Inappropriate content"
        case .spam: "Spam or scam"
        case .underage: "Looks under 18"
        case .other: "Something else"
        }
    }
}

/// A report as submitted. Write-only from the client's point of view —
/// moderation reads it, the reporter cannot, matching the Firestore rules.
struct Report: Identifiable, Equatable, Sendable {
    var id: String
    var reportedUserID: String
    var reportedDisplayName: String
    var reason: ReportReason
    var details: String?
    var createdAt: Date
}
