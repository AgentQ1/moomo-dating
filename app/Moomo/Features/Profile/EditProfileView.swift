import SwiftUI

/// Edit name, bio, interests, and location. Photos have their own screen.
///
/// Edits a draft copy and saves through `SessionStore.updateProfile` — the
/// single write path — so a cancelled edit changes nothing.
struct EditProfileView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Profile
    @State private var isSaving = false

    private let original: Profile

    init(profile: Profile) {
        original = profile
        _draft = State(initialValue: profile)
    }

    private var hasChanges: Bool { draft != original }

    private var canSave: Bool {
        hasChanges
        && !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                section("Name") {
                    MoomoTextField(
                        placeholder: "First name",
                        text: $draft.displayName,
                        characterLimit: 30
                    )
                    .accessibilityIdentifier("editProfile.name")
                }

                section("Bio") {
                    MoomoTextEditor(
                        placeholder: "I'm into photography, long coffees, and terrible puns…",
                        text: $draft.bio,
                        characterLimit: 300
                    )
                    .accessibilityIdentifier("editProfile.bio")
                }

                section("Looking for") {
                    DatingIntentionOptions(selection: $draft.datingIntention)

                    Label(
                        "Baybe only introduces you to people whose answer fits yours.",
                        systemImage: "person.2.fill"
                    )
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)
                }

                section("Interests") {
                    FlowLayout(spacing: Space.xs) {
                        ForEach(InterestCatalog.options, id: \.self) { option in
                            InterestChip(
                                label: option,
                                isSelected: draft.interests.contains(option)
                            ) {
                                if draft.interests.contains(option) {
                                    draft.interests.remove(option)
                                } else {
                                    draft.interests.insert(option)
                                }
                            }
                        }
                    }
                }

                section("City") {
                    VStack(spacing: Space.xs) {
                        ForEach(CityCatalog.cities, id: \.display) { city in
                            SelectableCard(
                                title: city.shortDisplay,
                                isSelected: draft.location == city
                            ) {
                                draft.location = city
                            }
                        }
                    }

                    Label(
                        "Baybe shows your city, never your exact location.",
                        systemImage: "lock.shield.fill"
                    )
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, Space.xs)
                }

                PrimaryButton(title: "Save", isEnabled: canSave, isLoading: isSaving) {
                    Task { await save() }
                }
                .padding(.top, Space.sm)
                .padding(.bottom, Space.xxl)
                .accessibilityIdentifier("editProfile.save")
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.md)
        }
        .background(Palette.canvas)
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() async {
        guard canSave, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        await session.updateProfile(draft)
        // `updateProfile` reports failures through the session's alert; only
        // a clean save leaves the screen.
        if session.error == nil { dismiss() }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title.uppercased())
                .font(Typography.sectionLabel)
                .tracking(Typography.sectionTracking)
                .foregroundStyle(Palette.ink)
            content()
        }
    }
}
