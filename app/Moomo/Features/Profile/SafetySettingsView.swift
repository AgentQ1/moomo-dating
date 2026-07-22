import SwiftUI

/// Safety & Privacy: blocked-user management and how safety works.
///
/// Only controls that genuinely function appear here — blocked users are a
/// real list backed by the safety service; everything else is information,
/// clearly presented as such.
@MainActor
final class SafetySettingsModel: ObservableObject {
    @Published private(set) var blockedUsers: [BlockedUser] = []

    private let safety: SafetyService
    private var observationTask: Task<Void, Never>?

    init(safety: SafetyService) {
        self.safety = safety
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await blocked in safety.blockedUsersStream {
                guard !Task.isCancelled else { return }
                self.blockedUsers = blocked
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    func unblock(_ userID: String) {
        Task { [safety] in await safety.unblock(userID) }
    }
}

struct SafetySettingsView: View {
    @StateObject private var model: SafetySettingsModel
    @State private var presentedDocument: LegalDocument?

    init(safety: SafetyService) {
        _model = StateObject(wrappedValue: SafetySettingsModel(safety: safety))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                blockedSection
                howItWorks
                contactCard
                Color.clear.frame(height: Space.xxl)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.md)
        }
        .background(Palette.canvas)
        .navigationTitle("Safety & Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentedDocument) { document in
            LegalDocumentView(document: document)
        }
    }

    // MARK: - Blocked users

    private var blockedSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("BLOCKED USERS")
                .font(Typography.sectionLabel)
                .tracking(Typography.sectionTracking)
                .foregroundStyle(Palette.ink)

            if model.blockedUsers.isEmpty {
                Text("You haven't blocked anyone. You can block someone from any call or after-call screen.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.md)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(Palette.surface)
                    )
                    .shadow(Shadows.card)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.blockedUsers.enumerated()), id: \.element.id) { index, blocked in
                        HStack(spacing: Space.sm) {
                            AvatarView(name: blocked.displayName, size: Size.chatAvatar)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(blocked.displayName)
                                    .font(Typography.rowTitle)
                                    .foregroundStyle(Palette.textPrimary)
                                Text("Blocked \(blocked.blockedAt.formatted(.relative(presentation: .named)))")
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.textSecondary)
                            }

                            Spacer()

                            Button("Unblock") {
                                model.unblock(blocked.userID)
                            }
                            .font(Typography.pill)
                            .foregroundStyle(Palette.blue)
                            .padding(.horizontal, Space.sm)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Palette.blueTint))
                            .accessibilityIdentifier("safety.unblock.\(blocked.displayName)")
                        }
                        .padding(.horizontal, Space.md)
                        .frame(minHeight: Size.menuRowHeight)

                        if index < model.blockedUsers.count - 1 {
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
        }
    }

    // MARK: - Information

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("HOW MOOMO KEEPS YOU SAFE")
                .font(Typography.sectionLabel)
                .tracking(Typography.sectionTracking)
                .foregroundStyle(Palette.ink)

            VStack(alignment: .leading, spacing: Space.sm) {
                infoRow(
                    icon: "hand.raised.fill",
                    text: "Blocking is instant and silent — they're removed from your Discover, matches, and chats, and never told."
                )
                infoRow(
                    icon: "flag.fill",
                    text: "Every report is reviewed. Reporting is anonymous."
                )
                infoRow(
                    icon: "mappin.slash",
                    text: "Only your city is ever shown. Baybe never collects your exact location."
                )
            }
            .padding(Space.md)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
            .shadow(Shadows.card)

            ProfileRowButton(title: "Privacy Policy", icon: "lock.shield") {
                presentedDocument = .privacy
            }
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
            .shadow(Shadows.card)
        }
    }

    private var contactCard: some View {
        Label(
            "Need help with something urgent? Email moomolab@gmail.com.",
            systemImage: "envelope.fill"
        )
        .font(Typography.body)
        .foregroundStyle(Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.blueTint)
        )
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: Size.iconSmall))
                .foregroundStyle(Palette.blue)
                .frame(width: 22)
                .padding(.top, 2)
            Text(text)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
