import Foundation

/// The social-graph services behind the main tabs, wired into one consistent
/// world: a mutual like creates a conversation and a notification; a block
/// removes the person from Discover, matchmaking, matches, and chat.
///
/// One instance per signed-in session (`RootView` keys the tab shell by uid),
/// so per-session state never leaks across accounts.
@MainActor
final class AppServices: ObservableObject {

    let discovery: DiscoveryService
    let calls: CallService
    let media: CallMediaService
    let callPermissions: CallPermissionsChecking
    let matches: MatchService
    let chat: ChatService
    let safety: SafetyService
    let notifications: NotificationService
    let boost: BoostService

    init(
        discovery: DiscoveryService,
        calls: CallService,
        media: CallMediaService,
        callPermissions: CallPermissionsChecking,
        matches: MatchService,
        chat: ChatService,
        safety: SafetyService,
        notifications: NotificationService,
        boost: BoostService
    ) {
        self.discovery = discovery
        self.calls = calls
        self.media = media
        self.callPermissions = callPermissions
        self.matches = matches
        self.chat = chat
        self.safety = safety
        self.notifications = notifications
        self.boost = boost
    }

    /// One live graph per uid.
    ///
    /// `MainTabView.init` runs on every parent render; building the graph
    /// there attached (and discarded) a fresh set of Firestore listeners per
    /// render. This weak cache hands back the instance the installed
    /// `StateObject` already owns; when the tab shell goes away, the graph
    /// deallocates and the entry clears itself.
    private static let activeGraphs = NSMapTable<NSString, AppServices>.strongToWeakObjects()

    static func retained(for user: User) -> AppServices {
        if let existing = activeGraphs.object(forKey: user.id as NSString) {
            return existing
        }
        let created = make(for: user)
        activeGraphs.setObject(created, forKey: user.id as NSString)
        return created
    }

    /// The composition rule, mirroring `MoomoApp.makeAuthService`: a real
    /// backend gets the Firebase-backed graph, the mock world exists only in
    /// DEBUG (tests, previews, simulator without a plist). A release build
    /// that lost its backend crashes at launch rather than quietly wiring the
    /// tabs to an in-memory world that loses everything.
    static func make(for user: User) -> AppServices {
        switch BackendConfiguration.current {
        case .firebase:
            #if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
            return .firestore(uid: user.id)
            #else
            fatalError(
                "GoogleService-Info.plist is present but the Firebase SDK is not fully linked (Firestore + Functions required)."
            )
            #endif

        case .localMock(let reason):
            #if DEBUG
            return .mock()
            #else
            fatalError("Release builds require Firebase. Mock reason: \(reason.explanation).")
            #endif
        }
    }

    #if canImport(FirebaseFirestore) && canImport(FirebaseFunctions)
    /// The Firebase-backed graph. No cross-service closures here: the ripple
    /// the mock wired by hand (match → conversation + notification, block →
    /// cascade) runs server-side in Cloud Functions, and each service's
    /// listener simply observes the result.
    static func firestore(uid: String) -> AppServices {
        let safety = FirestoreSafetyService(uid: uid)
        return AppServices(
            discovery: BlockFilteringDiscoveryService(
                base: FirestoreDiscoveryService(uid: uid),
                safety: safety
            ),
            calls: FirestoreCallService(uid: uid),
            media: Self.realMedia(),
            callPermissions: SystemCallPermissions(),
            matches: FirestoreMatchService(uid: uid),
            chat: FirestoreChatService(uid: uid),
            safety: safety,
            notifications: FirestoreNotificationService(uid: uid),
            boost: FirestoreBoostService(uid: uid)
        )
    }

    /// LiveKit when the SDK is linked (always, in a correctly configured
    /// build); otherwise the honest dead-end that fails every join loudly.
    /// Never a silent mock in a real backend build.
    private static func realMedia() -> CallMediaService {
        #if canImport(LiveKit)
        LiveKitCallMediaService()
        #else
        UnavailableCallMediaService()
        #endif
    }
    #endif

    #if DEBUG
    /// The wired-up mock graph, for tests, previews, and the no-backend
    /// simulator. The closures stand in for the backend triggers: they are
    /// the only cross-service coupling, and they run the same direction the
    /// server-side versions do.
    static func mock() -> AppServices {
        let chat = MockChatService()
        let notifications = MockNotificationService()

        let matches = MockMatchService(onMatch: { match in
            await chat.createConversation(for: match)
            await notifications.add(AppNotification(
                id: UUID().uuidString,
                kind: .match,
                title: "It's a match with \(match.candidate.displayName)!",
                body: "You both said yes. Say hi in Chat.",
                sentAt: Date(),
                isRead: false
            ))
        })

        let safety = MockSafetyService(onBlock: { userID in
            await matches.removeMatches(with: userID)
            await chat.removeConversations(with: userID)
        })

        let calls = MockCallService(isBlocked: { await safety.isBlocked($0) })

        return AppServices(
            discovery: BlockFilteringDiscoveryService(
                base: MockDiscoveryService(),
                safety: safety
            ),
            calls: calls,
            // No capture, no prompts: the mock world simulates media and says
            // so on the call screen, so asking for mic permission would be
            // requesting access it never uses.
            media: MockCallMediaService(),
            callPermissions: StubCallPermissions(),
            matches: matches,
            chat: chat,
            safety: safety,
            notifications: notifications,
            boost: MockBoostService()
        )
    }
    #endif
}

/// Removes blocked users from any discovery source.
///
/// A wrapper rather than logic inside the mock, so the same guarantee holds
/// verbatim over the Firestore-backed service later — server-side filtering
/// is the real fix, but the client must never render a blocked person even
/// if a stale page slips through.
struct BlockFilteringDiscoveryService: DiscoveryService {
    let base: DiscoveryService
    let safety: SafetyService

    func loadDiscovery() async throws -> DiscoveryState {
        var state = try await base.loadDiscovery()
        let blocked = Set(await safety.blockedUsers().map(\.userID))
        guard !blocked.isEmpty else { return state }

        if let featured = state.featured, blocked.contains(featured.id) {
            state.featured = nil
        }
        state.nearby.removeAll { blocked.contains($0.id) }
        return state
    }
}
