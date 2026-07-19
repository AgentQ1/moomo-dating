import Foundation

/// A person as shown in Discover. Deliberately not `Profile`: this is the
/// public projection — no date of birth, no exact location, no private fields.
/// It maps to `publicProfiles/{uid}` when Firestore lands.
struct DiscoveryCandidate: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var age: Int
    var city: String
    /// "Marketing Student" — the second line of the call-screen identity
    /// overlay. Optional: older public profiles don't carry one.
    var occupation: String?
    /// Storage path of their primary photo (`photoPaths[0]` in the public
    /// projection, `photoPath` in a participant summary). Nil renders the
    /// initials placeholder.
    var photoPath: String?
    var isOnline: Bool
    /// They've signalled interest and are waiting on a call.
    var wantsToTalk: Bool
    /// Server-granted photo verification. Read from the public projection,
    /// never written by the client — a self-serve badge would be worthless.
    var isVerified: Bool = false
    var pronoun: CandidatePronoun
}

/// Used only to render "Talk to Them" / "Talk to Him" / "Talk to Her" — the
/// reference shows "Talk to Him". Defaults to `they`, which is always safe when
/// a user hasn't told us.
enum CandidatePronoun: String, Sendable {
    case they
    case he
    case she

    var objectForm: String {
        switch self {
        case .they: "Them"
        case .he: "Him"
        case .she: "Her"
        }
    }
}

/// What Discover shows.
struct DiscoveryState: Equatable, Sendable {
    /// The person in the centre of the hero card.
    var featured: DiscoveryCandidate?
    /// The avatars orbiting the hero.
    var nearby: [DiscoveryCandidate]
    var level: Int
    // Unread state deliberately lives with `NotificationService`, not here —
    // discovery describes who's around, not the bell.
    var community: String?
}

/// Source of Discover data.
///
/// A protocol so the Firestore implementation drops in without touching the
/// view: the mock and the real service are interchangeable.
protocol DiscoveryService: Sendable {
    func loadDiscovery() async throws -> DiscoveryState
}

enum DiscoveryError: LocalizedError, Equatable {
    case offline
    case noUsersAvailable

    var errorDescription: String? {
        switch self {
        case .offline: "You're offline. Check your connection."
        case .noUsersAvailable: "No one's around right now."
        }
    }
}

/// Local Discover data.
///
/// Realistic shape and realistic latency, so loading and empty states are
/// exercised for real. Replaced wholesale by the Firestore implementation.
struct MockDiscoveryService: DiscoveryService {
    var latency: Duration = .milliseconds(600)
    /// Drives the empty and offline states from the debug menu and tests.
    var result: Result<DiscoveryState, DiscoveryError> = .success(.sample)

    func loadDiscovery() async throws -> DiscoveryState {
        try await Task.sleep(for: latency)
        return try result.get()
    }
}

extension DiscoveryState {
    static let sample = DiscoveryState(
        featured: DiscoveryCandidate(
            id: "u-featured",
            displayName: "Kenji",
            age: 26,
            city: "Chicago",
            occupation: "Marketing Student",
            photoPath: nil,
            isOnline: true,
            wantsToTalk: true,
            isVerified: true,
            pronoun: .he
        ),
        nearby: [
            DiscoveryCandidate(id: "u-1", displayName: "Anaya", age: 24, city: "Chicago", occupation: "Graphic Designer", photoPath: nil, isOnline: true, wantsToTalk: false, isVerified: true, pronoun: .she),
            DiscoveryCandidate(id: "u-2", displayName: "Mei", age: 27, city: "Chicago", occupation: "Nurse", photoPath: nil, isOnline: true, wantsToTalk: false, isVerified: true, pronoun: .she),
            DiscoveryCandidate(id: "u-3", displayName: "Zara", age: 25, city: "Evanston", occupation: "Grad Student", photoPath: nil, isOnline: false, wantsToTalk: false, isVerified: true, pronoun: .she),
            DiscoveryCandidate(id: "u-4", displayName: "Priya", age: 23, city: "Chicago", occupation: "Software Engineer", photoPath: nil, isOnline: true, wantsToTalk: false, isVerified: true, pronoun: .she),
            DiscoveryCandidate(id: "u-5", displayName: "Sofia", age: 28, city: "Oak Park", occupation: "Barista", photoPath: nil, isOnline: true, wantsToTalk: false, isVerified: true, pronoun: .she)
        ],
        level: 1,
        community: "IIT Stuart School of Business"
    )

    static let empty = DiscoveryState(
        featured: nil, nearby: [], level: 1,
        community: "IIT Stuart School of Business"
    )
}
