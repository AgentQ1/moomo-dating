import SwiftUI

/// The five destinations, in reference order.
enum Tab: Int, CaseIterable, Identifiable {
    case discover
    case calls
    case matches
    case chat
    case profile

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .discover: "Discover"
        case .calls: "Calls"
        case .matches: "Matches"
        case .chat: "Chat"
        case .profile: "Profile"
        }
    }

    /// The reference uses outline icons for inactive tabs and a filled icon
    /// for the active one.
    var icon: String {
        switch self {
        case .discover: "star"
        case .calls: "phone"
        case .matches: "heart"
        case .chat: "message"
        case .profile: "person"
        }
    }

    var selectedIcon: String {
        switch self {
        case .discover: "star.fill"
        case .calls: "phone.fill"
        case .matches: "heart.fill"
        case .chat: "message.fill"
        case .profile: "person.fill"
        }
    }

    /// Every tab ships: each one has real content now, in Debug and Release
    /// alike. (The Release gating this replaced existed to keep "Not built
    /// yet." out of shipping builds.)
    static var available: [Tab] { allCases }
}

/// The floating tab bar from the reference: a white rounded card inset from
/// the screen edges, sitting above the home indicator rather than filling the
/// bottom safe area like a system tab bar.
struct MoomoTabBar: View {
    @Binding var selection: Tab
    /// Conversations waiting on the local user — the number on the Chat icon.
    /// Zero hides the badge.
    var chatBadge: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.available) { tab in
                Button {
                    guard selection != tab else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: selection == tab ? tab.selectedIcon : tab.icon)
                            .font(.system(size: Size.tabIcon, weight: .regular))
                            .frame(height: 26)
                            .overlay(alignment: .topTrailing) {
                                if tab == .chat && chatBadge > 0 {
                                    TabBadge(count: chatBadge)
                                        .offset(x: 12, y: -4)
                                }
                            }
                        Text(tab.label)
                            .font(Typography.caption)
                    }
                    .foregroundStyle(selection == tab ? Palette.blue : Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityValue(
                    tab == .chat && chatBadge > 0 ? "\(chatBadge) waiting" : ""
                )
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .frame(height: Size.tabBarHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.tabBar, style: .continuous)
                .fill(Palette.surface)
        )
        .shadow(Shadows.tabBar)
        .padding(.horizontal, Space.sm)
        .animation(Motion.tap, value: selection)
    }
}

/// The red count bubble on a tab icon, in the notification-dot red the bell
/// already uses. Caps at 99+ so the pill can't outgrow the icon.
private struct TabBadge: View {
    var count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Palette.notificationDot))
            .overlay(Capsule().stroke(Palette.surface, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// The main app shell.
///
/// Deliberately not a `TabView`: the reference's bar floats above the content
/// with its own radius, inset, and shadow, which a system tab bar can't be
/// made to do.
///
/// Owns the per-session service graph, the models behind each tab (held here
/// so tab state survives switching), and the call coordinator — a call runs
/// *above* the tabs and must outlive whichever screen started it.
struct MainTabView: View {
    @EnvironmentObject private var session: SessionStore

    @StateObject private var services: AppServices
    @StateObject private var coordinator: CallCoordinator
    @StateObject private var discoverModel: DiscoverModel
    @StateObject private var callsModel: CallsModel
    @StateObject private var matchesModel: MatchesModel
    @StateObject private var chatListModel: ChatListModel
    @StateObject private var notificationsModel: NotificationsModel
    @StateObject private var boostModel: BoostModel
    @StateObject private var incomingCallModel: IncomingCallModel

    @State private var selection: Tab = .discover
    @State private var chatPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    /// A realtime listener reported a failure: the lists on screen may be
    /// stale. Cleared the moment any listener delivers again.
    @State private var isLiveDataPaused = false

    init(user: User) {
        // One shared service graph per session, resolved through the per-uid
        // cache INSIDE each StateObject autoclosure. This init re-runs on
        // every parent render; anything built outside the autoclosures would
        // wire a fresh set of Firestore listeners each time and throw them
        // away. The autoclosures run once per view identity, and every one of
        // them resolves to the same cached instance.
        _services = StateObject(wrappedValue: AppServices.retained(for: user))
        _coordinator = StateObject(wrappedValue: CallCoordinator(services: .retained(for: user)))
        _discoverModel = StateObject(wrappedValue: DiscoverModel(service: AppServices.retained(for: user).discovery))
        _callsModel = StateObject(wrappedValue: CallsModel(calls: AppServices.retained(for: user).calls))
        _matchesModel = StateObject(wrappedValue: MatchesModel(
            service: AppServices.retained(for: user).matches,
            chat: AppServices.retained(for: user).chat,
            safety: AppServices.retained(for: user).safety
        ))
        _chatListModel = StateObject(wrappedValue: ChatListModel(
            service: AppServices.retained(for: user).chat,
            safety: AppServices.retained(for: user).safety
        ))
        _notificationsModel = StateObject(wrappedValue: NotificationsModel(service: AppServices.retained(for: user).notifications))
        _boostModel = StateObject(wrappedValue: BoostModel(service: AppServices.retained(for: user).boost))
        _incomingCallModel = StateObject(wrappedValue: IncomingCallModel(calls: AppServices.retained(for: user).calls))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.canvas.ignoresSafeArea()

            Group {
                switch selection {
                case .discover:
                    DiscoverView(
                        model: discoverModel,
                        notifications: notificationsModel,
                        boost: boostModel,
                        coordinator: coordinator
                    )

                case .calls:
                    CallsView(
                        model: callsModel,
                        coordinator: coordinator,
                        onStartMatching: { selection = .discover }
                    )

                case .matches:
                    MatchesView(
                        model: matchesModel,
                        onOpenConversation: openConversation,
                        onDiscover: { selection = .discover }
                    )

                case .chat:
                    NavigationStack(path: $chatPath) {
                        ChatListView(
                            model: chatListModel,
                            onOpen: { chatPath.append(ChatRoute(conversationID: $0)) },
                            onDiscover: { selection = .discover }
                        )
                        .navigationDestination(for: ChatRoute.self) { route in
                            ChatDetailView(
                                conversationID: route.conversationID,
                                service: services.chat,
                                safety: services.safety
                            )
                        }
                    }

                case .profile:
                    NavigationStack(path: $profilePath) {
                        ProfileView()
                            .navigationDestination(for: ProfileRoute.self) { route in
                                profileDestination(route)
                            }
                    }
                }
            }

            if isTabBarVisible {
                MoomoTabBar(selection: $selection, chatBadge: chatListModel.awaitingYouCount)
            }
        }
        .overlay(alignment: .top) {
            if isLiveDataPaused {
                Label("Live updates are paused — check your connection.", systemImage: "wifi.exclamationmark")
                    .font(Typography.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.xs)
                    .background(Capsule().fill(Palette.coral))
                    .padding(.top, Space.xs)
                    .transition(.opacity)
                    .accessibilityIdentifier("main.liveDataPaused")
            }
        }
        .animation(Motion.transition, value: isLiveDataPaused)
        .overlay(alignment: .top) {
            // Suppressed while any flow exists: a running call (even
            // minimised) always outranks a new ring, and the accept callable
            // would answer "unavailable" for a busy user anyway.
            if coordinator.flow == nil, let invite = incomingCallModel.invite {
                IncomingCallBanner(
                    invite: invite,
                    onAccept: {
                        guard let accepted = incomingCallModel.accept() else { return }
                        coordinator.acceptIncoming(accepted)
                    },
                    onDecline: { incomingCallModel.decline() }
                )
                .padding(.horizontal, Space.md)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.transition, value: incomingCallModel.invite)
        .task {
            for await failure in FirestoreListeners.failures.stream() {
                isLiveDataPaused = failure != nil
            }
        }
        .fullScreenCover(isPresented: $coordinator.isPresenting) {
            if let flow = coordinator.flow {
                CallFlowView(model: flow, coordinator: coordinator)
            }
        }
        .onAppear {
            coordinator.openConversation = { openConversation($0) }
        }
    }

    /// Detail screens own the whole viewport — a floating bar over a chat
    /// composer or a photo grid would sit on the controls.
    private var isTabBarVisible: Bool {
        switch selection {
        case .chat: chatPath.isEmpty
        case .profile: profilePath.isEmpty
        default: true
        }
    }

    /// The one way a conversation opens, from anywhere (match card, match
    /// celebration): switch to Chat and push it.
    private func openConversation(_ conversationID: String) {
        selection = .chat
        chatPath = NavigationPath()
        chatPath.append(ChatRoute(conversationID: conversationID))
    }

    @ViewBuilder
    private func profileDestination(_ route: ProfileRoute) -> some View {
        switch route {
        case .editProfile:
            EditProfileView(profile: session.user?.profile ?? Profile())

        case .editPhotos:
            EditPhotosView(model: EditPhotosModel(
                uid: session.user?.id ?? "",
                photos: session.user?.profile.photos ?? [],
                persist: { [weak session] photos in
                    guard let session, var profile = session.user?.profile else { return false }
                    profile.photos = photos
                    // Awaited, not fire-and-forget: the editor sequences its
                    // saves and gates byte deletion on this result.
                    return await session.updateProfile(profile)
                }
            ))

        case .safety:
            SafetySettingsView(safety: services.safety)
        }
    }
}
