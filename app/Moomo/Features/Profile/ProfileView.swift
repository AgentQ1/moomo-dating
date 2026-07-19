import SwiftUI

/// Where Profile rows navigate. Value-typed for the tab's `NavigationStack`.
enum ProfileRoute: Hashable {
    case editProfile
    case editPhotos
    case safety
}

/// The Profile tab: the signed-in user's own profile, editing, safety, and
/// account controls. Every row does something real.
struct ProfileView: View {
    @EnvironmentObject private var session: SessionStore

    @State private var presentedDocument: LegalDocument?
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDeletion = false

    private var user: User? { session.user }
    private var profile: Profile { user?.profile ?? Profile() }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.md) {
                header
                    .padding(.top, Space.lg)

                editingSection

                legalSection

                accountSection

                // Clears the floating tab bar, which overlays the scroll view.
                Color.clear.frame(height: Size.tabBarHeight + Space.xxl)
            }
            .padding(.horizontal, Space.gutter)
        }
        .background(Palette.canvas)
        .sheet(item: $presentedDocument) { document in
            LegalDocumentView(document: document)
        }
        .confirmationDialog(
            "Sign out of Moomo?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) { session.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your profile stays — sign back in any time.")
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                Task { await session.deleteAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your profile and photos. It cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Space.sm) {
            photo

            VStack(spacing: Space.xxs) {
                Text(displayNameLine)
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.ink)

                if let location = profile.location {
                    Text(location.shortDisplay)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)

            if !profile.bio.isEmpty {
                Text(profile.bio)
                    .font(Typography.body)
                    .lineSpacing(Typography.bodyLineSpacing)
                    .foregroundStyle(Palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            completionPill
        }
        .frame(maxWidth: .infinity)
    }

    private var completionPill: some View {
        let percent = ProfileRequirements.completionPercentage(for: profile)
        return Text("\(percent)% Profile Complete")
            .font(Typography.pill)
            .foregroundStyle(Palette.blue)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .background(Capsule().fill(Palette.blueTint))
            .accessibilityLabel("Profile \(percent) percent complete")
    }

    @ViewBuilder
    private var photo: some View {
        if let primary = profile.primaryPhotoPath {
            RemotePhotoView(
                remotePath: primary,
                service: PhotoServiceFactory.make()
            )
            .frame(width: 128, height: 128)
            .clipShape(Circle())
            .accessibilityElement()
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel("Your main photo")
        } else {
            AvatarView(name: profile.displayName, size: 128)
        }
    }

    private var displayNameLine: String {
        let name = profile.displayName.isEmpty ? "You" : profile.displayName
        if let age = profile.age { return "\(name), \(age)" }
        return name
    }

    // MARK: - Sections

    private var editingSection: some View {
        VStack(spacing: 0) {
            ProfileNavRow(title: "Edit profile", icon: "pencil", route: .editProfile)
            Divider().background(Palette.separator)
            ProfileNavRow(title: "Photos", icon: "photo.on.rectangle", route: .editPhotos)
            Divider().background(Palette.separator)
            ProfileNavRow(title: "Safety & Privacy", icon: "shield.lefthalf.filled", route: .safety)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .shadow(Shadows.card)
    }

    private var legalSection: some View {
        VStack(spacing: 0) {
            ProfileRowButton(title: "Privacy Policy", icon: "lock.shield") {
                presentedDocument = .privacy
            }
            Divider().background(Palette.separator)
            ProfileRowButton(title: "Terms of Service", icon: "doc.text") {
                presentedDocument = .terms
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .shadow(Shadows.card)
    }

    private var accountSection: some View {
        VStack(spacing: 0) {
            ProfileRowButton(
                title: "Sign out",
                icon: "rectangle.portrait.and.arrow.right",
                role: .destructive
            ) {
                isConfirmingSignOut = true
            }

            Divider().background(Palette.separator)

            ProfileRowButton(
                title: session.isDeletingAccount ? "Deleting…" : "Delete account",
                icon: "trash",
                role: .destructive
            ) {
                isConfirmingDeletion = true
            }
            .disabled(session.isDeletingAccount)
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .shadow(Shadows.card)
    }
}

/// A profile row that pushes a destination. Same look as `ProfileRowButton`,
/// but a `NavigationLink` so the tab's stack drives it.
struct ProfileNavRow: View {
    var title: String
    var icon: String
    var route: ProfileRoute

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: Size.iconMedium))
                    .foregroundStyle(Palette.blue)
                    .frame(width: 28)

                Text(title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: Size.menuRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.row.\(title)")
    }
}

/// A standard tappable row for the profile lists.
struct ProfileRowButton: View {
    var title: String
    var icon: String
    var role: ButtonRole?
    var action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: Size.iconMedium))
                    .foregroundStyle(role == .destructive ? Palette.coral : Palette.blue)
                    .frame(width: 28)

                Text(title)
                    .font(Typography.rowTitle)
                    .foregroundStyle(role == .destructive ? Palette.coral : Palette.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: Size.menuRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.row.\(title)")
    }
}
