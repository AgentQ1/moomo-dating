import SwiftUI

/// Confirmation bottom sheet for unmatching: a private reason, an optional
/// block on top, and one clearly destructive confirm. Used from the Chat
/// list's swipe action, the chat thread's menu, and the match card's menu.
struct UnmatchSheet: View {
    var candidateName: String
    /// Runs the unmatch. Returns nil on success (the sheet dismisses) or the
    /// failure text (the sheet stays up and shows it).
    var onConfirm: (UnmatchReason, _ alsoBlock: Bool) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var reason: UnmatchReason = .noReason
    @State private var alsoBlock = false
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("They'll disappear from your matches and the chat will close for both of you. Your reason stays private — \(candidateName) never sees it.")
                        .font(Typography.body)
                        .lineSpacing(Typography.bodyLineSpacing)
                        .foregroundStyle(Palette.textSecondary)

                    VStack(spacing: 0) {
                        ForEach(Array(UnmatchReason.allCases.enumerated()), id: \.element.id) { index, option in
                            ReasonRow(reason: option, isSelected: reason == option) {
                                reason = option
                                // Harm-shaped reasons default to blocking too;
                                // still the user's call either way.
                                if option.isSerious && !alsoBlock {
                                    alsoBlock = true
                                }
                            }
                            if index < UnmatchReason.allCases.count - 1 {
                                Divider().background(Palette.separator)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(Palette.surface)
                    )
                    .shadow(Shadows.card)

                    blockToggle

                    if let failure {
                        ValidationMessage(message: failure)
                    }

                    PrimaryButton(
                        title: "Unmatch \(candidateName)",
                        isLoading: isWorking
                    ) {
                        Task { await confirm() }
                    }
                    .accessibilityIdentifier("unmatch.confirm")

                    Button("Cancel") { dismiss() }
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: Size.minTapTarget)
                        .padding(.bottom, Space.xl)
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
            }
            .background(Palette.canvas)
            .navigationTitle("Unmatch \(candidateName)?")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWorking)
    }

    private var blockToggle: some View {
        Button {
            alsoBlock.toggle()
        } label: {
            HStack(alignment: .top, spacing: Space.sm) {
                Image(systemName: alsoBlock ? "checkmark.square.fill" : "square")
                    .font(.system(size: Size.iconMedium))
                    .foregroundStyle(alsoBlock ? Palette.blue : Palette.checkboxBorder)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Also block \(candidateName)")
                        .font(Typography.rowTitleSmall)
                        .foregroundStyle(Palette.ink)
                    Text("They won't see you in Discover or be able to contact you again. They won't be told.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.md)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
            .shadow(Shadows.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.tap, value: alsoBlock)
        .accessibilityAddTraits(alsoBlock ? [.isSelected] : [])
        .accessibilityIdentifier("unmatch.alsoBlock")
    }

    private func confirm() async {
        guard !isWorking else { return }
        isWorking = true
        failure = await onConfirm(reason, alsoBlock)
        isWorking = false
        if failure == nil { dismiss() }
    }
}

/// A compact radio row — `SelectableCard` is sized for onboarding steps and
/// seven of them would outgrow a bottom sheet on small phones.
private struct ReasonRow: View {
    var reason: UnmatchReason
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: Size.iconMedium))
                    .foregroundStyle(isSelected ? Palette.blue : Palette.checkboxBorder)

                Text(reason.label)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: Size.minTapTarget + Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("unmatch.reason.\(reason.rawValue)")
    }
}
