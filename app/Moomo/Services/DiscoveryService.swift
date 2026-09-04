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

/// A candidate's pronoun, for copy that has to refer to them in the third
/// person. Defaults to `they`, which is always safe when a user hasn't told us.
///
/// `objectForm` rendered the hero CTA ("Talk to Him") until the Discover
/// redesign replaced it with "Nearby"; nothing calls it right now. Kept because
/// the mapping is the app's one answer to this question, and the next screen
/// that names someone should not invent a second one.
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
    /// Real connectivity loss, or the backend saying `unavailable` (outage /
    /// maintenance kill switch). ONLY these may render the offline card —
    /// an auth, App Check, permission, or config failure dressed up as
    /// "check your connection" sends the user debugging their Wi-Fi while
    /// the real fault sits server-side, invisible.
    case offline
    case noUsersAvailable
    /// The backend's per-user rate limit refused this refresh.
    case rateLimited
    /// There is no live Firebase session to speak for: either the gate
    /// refused to call the backend at all, or the 401 was diagnosed down to
    /// the missing ID token. The auth listener is what actually signs the
    /// user out and routes to welcome — this state just says so honestly
    /// instead of blaming the load.
    case sessionExpired
    /// Everything else — auth/App Check rejection, missing function,
    /// permission, bad config. `code` is the diagnostic name (e.g.
    /// "unauthenticated"); it is logged, and shown in the card in DEBUG.
    case loadFailed(code: String)

    var errorDescription: String? {
        switch self {
        case .offline: "You're offline. Check your connection."
        case .noUsersAvailable: "No one's around right now."
        case .rateLimited: "Discover is refreshing too often. Give it a moment and try again."
        case .sessionExpired: "Your session has expired. Please sign in again."
        case .loadFailed(let code):
            #if DEBUG
            "Discover couldn't load. Please try again in a moment.\n(Debug: \(code))"
            #else
            "Discover couldn't load. Please try again in a moment."
            #endif
        }
    }

    /// The classifier's untreated 401 verdict. Matching the exact code is
    /// deliberate: only the bare "unauthenticated" may trigger the auth
    /// gate's refresh-retry-diagnose pass — an already refined code must
    /// pass through it untouched, or the retry would loop.
    var isBareUnauthenticated: Bool {
        self == .loadFailed(code: DiscoveryErrorClassifier.unauthenticatedCode)
    }
}

/// Maps raw transport/Firebase errors onto `DiscoveryError` — one table, so
/// the "what counts as offline" decision exists exactly once and is unit
/// tested. Pure Foundation: it works on error domain + code, so tests need
/// no Firebase and no network.
enum DiscoveryErrorClassifier {

    /// `FunctionsErrorDomain` in FirebaseFunctions — pinned here so this
    /// file stays Firebase-free; `DiscoveryErrorMappingTests` asserts the
    /// two constants never drift apart.
    static let functionsErrorDomain = "com.firebase.functions"
    /// `FirestoreErrorDomain` in FirebaseFirestore — same arrangement.
    static let firestoreErrorDomain = "FIRFirestoreErrorDomain"

    /// gRPC 16 — the backend's 401. One constant because two different
    /// rejections share it: `enforceAppCheck` refusing a tokenless app, and
    /// `requireAuth` refusing a missing ID token. `refineUnauthenticated`
    /// is what tells them apart.
    static let unauthenticatedCode = "unauthenticated"

    /// gRPC canonical codes, shared by the Functions and Firestore domains.
    private static let grpcNames: [Int: String] = [
        1: "cancelled", 2: "unknown", 3: "invalid-argument",
        4: "deadline-exceeded", 5: "not-found", 6: "already-exists",
        7: "permission-denied", 8: "resource-exhausted",
        9: "failed-precondition", 10: "aborted", 11: "out-of-range",
        12: "unimplemented", 13: "internal", 14: "unavailable",
        15: "data-loss", 16: unauthenticatedCode,
    ]
    private static let grpcUnavailable = 14
    private static let grpcResourceExhausted = 8

    /// URLSession failures that genuinely mean "the network is not there".
    /// Deliberately NOT the whole domain: `.cancelled` and friends are not
    /// connectivity problems and must not render the offline card.
    private static let urlConnectivityCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff,
    ]

    static func classify(_ error: Error) -> DiscoveryError {
        if let discovery = error as? DiscoveryError { return discovery }
        let nsError = error as NSError
        return classify(domain: nsError.domain, code: nsError.code)
    }

    static func classify(domain: String, code: Int) -> DiscoveryError {
        switch domain {
        case NSURLErrorDomain:
            return urlConnectivityCodes.contains(code)
                ? .offline
                : .loadFailed(code: "url-\(code)")
        case functionsErrorDomain, firestoreErrorDomain:
            if code == grpcUnavailable { return .offline }
            if code == grpcResourceExhausted { return .rateLimited }
            return .loadFailed(code: grpcNames[code] ?? "grpc-\(code)")
        default:
            return .loadFailed(code: "\(domain)#\(code)")
        }
    }

    /// Refines the backend's bare 401 into its actual cause, from two facts
    /// the Firebase layer gathers after the failure. Pure, so the decision
    /// table is testable without Firebase:
    ///  - no live session → `.sessionExpired`: the missing credential was
    ///    the ID token, and the fix is signing in, not retrying;
    ///  - App Check can't mint a token → the diagnostic names App Check,
    ///    because the backend enforces it on every callable and refuses
    ///    tokenless calls with exactly this 401;
    ///  - both credentials healthy → the bare code survives; the server
    ///    refused for a reason the client can't see.
    static func refineUnauthenticated(
        hasSession: Bool,
        appCheckProblem: String?
    ) -> DiscoveryError {
        guard hasSession else { return .sessionExpired }
        guard let appCheckProblem else { return .loadFailed(code: unauthenticatedCode) }
        return .loadFailed(code: "\(unauthenticatedCode) — App Check: \(appCheckProblem)")
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
