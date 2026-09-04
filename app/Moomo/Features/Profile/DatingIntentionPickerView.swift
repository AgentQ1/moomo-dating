import SwiftUI

/// Pick what you're on Baybe for.
///
/// Worth saying plainly in the UI, because it is not cosmetic: this narrows who
/// Discover shows and who matchmaking will pair you with
/// (`MatchPreferences.areIntentionsCompatible`, mirrored server-side). People
/// should know they are turning others away.
struct DatingIntentionPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selection: DatingIntention?

    private let onSave: (DatingIntention) -> Void

    init(current: DatingIntention?, onSave: @escaping (DatingIntention) -> Void) {
        _selection = State(initialValue: current)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Baybe only introduces you to people whose answer fits yours.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Space.xxs)

                    DatingIntentionOptions(selection: $selection)

                    PrimaryButton(title: "Save", isEnabled: selection != nil) {
                        guard let selection else { return }
                        onSave(selection)
                        dismiss()
                    }
                    .padding(.top, Space.sm)
                    .padding(.bottom, Space.xxl)
                    .accessibilityIdentifier("intention.save")
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
            }
            .background(Palette.canvas)
            .navigationTitle("Looking for")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("intention.cancel")
                }
            }
        }
    }
}

/// The option list on its own, so the Discover sheet and Edit Profile offer the
/// same six choices in the same order rather than drifting apart.
struct DatingIntentionOptions: View {
    @Binding var selection: DatingIntention?

    var body: some View {
        VStack(spacing: Space.xs) {
            ForEach(DatingIntention.allCases) { intention in
                SelectableCard(
                    title: intention.label,
                    subtitle: intention.detail,
                    isSelected: selection == intention
                ) {
                    selection = intention
                }
                .accessibilityIdentifier("intention.\(intention.rawValue)")
            }
        }
    }
}

#Preview {
    DatingIntentionPickerView(current: .longTerm) { _ in }
}
