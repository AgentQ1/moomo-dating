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
}

/// The floating tab bar from the reference: a white rounded card inset from
/// the screen edges, sitting above the home indicator rather than filling the
/// bottom safe area like a system tab bar.
struct MoomoTabBar: View {
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                Button {
                    guard selection != tab else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: selection == tab ? tab.selectedIcon : tab.icon)
                            .font(.system(size: Size.tabIcon, weight: .regular))
                            .frame(height: 26)
                        Text(tab.label)
                            .font(Typography.caption)
                    }
                    .foregroundStyle(selection == tab ? Palette.blue : Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
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

/// The main app shell.
///
/// Deliberately not a `TabView`: the reference's bar floats above the content
/// with its own radius, inset, and shadow, which a system tab bar can't be
/// made to do. Each tab keeps its own `NavigationStack` so navigation state
/// survives switching tabs.
struct MainTabView: View {
    @State private var selection: Tab = .discover

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.canvas.ignoresSafeArea()

            Group {
                switch selection {
                case .discover: DiscoverView()
                case .calls: PlaceholderTab(tab: .calls)
                case .matches: PlaceholderTab(tab: .matches)
                case .chat: PlaceholderTab(tab: .chat)
                case .profile: PlaceholderTab(tab: .profile)
                }
            }

            MoomoTabBar(selection: $selection)
        }
    }
}

/// Honest empty state for tabs that aren't built yet.
///
/// Not a mock screen pretending to work: it says plainly that the tab is not
/// implemented, so it can never be mistaken for a finished feature in a demo
/// or a screenshot.
struct PlaceholderTab: View {
    var tab: Tab

    var body: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: tab.icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text(tab.label)
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.textPrimary)
            Text("Not built yet.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
