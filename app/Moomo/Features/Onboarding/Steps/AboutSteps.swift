import SwiftUI

// MARK: - Bio

struct BioStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        MoomoTextEditor(
            placeholder: "I'm into photography, long coffees, and terrible puns…",
            text: Binding(
                get: { model.draft.profile.bio },
                set: { bio in model.update { $0.bio = bio } }
            ),
            characterLimit: 300
        )
        .accessibilityLabel("Bio")
    }
}

// MARK: - Interests

struct InterestsStep: View {
    @ObservedObject var model: OnboardingModel

    private let options = InterestCatalog.options

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            FlowLayout(spacing: Space.xs) {
                ForEach(options, id: \.self) { option in
                    InterestChip(
                        label: option,
                        isSelected: model.draft.profile.interests.contains(option)
                    ) {
                        model.update { profile in
                            if profile.interests.contains(option) {
                                profile.interests.remove(option)
                            } else {
                                profile.interests.insert(option)
                            }
                        }
                    }
                }
            }

            Text("\(model.draft.profile.interests.count) selected")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
    }
}
