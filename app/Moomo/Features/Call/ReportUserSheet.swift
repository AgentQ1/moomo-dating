import SwiftUI

/// Report someone: pick a reason, optionally add detail, submit. Used from
/// the live call, the decision screen, and (later) chat.
struct ReportUserSheet: View {
    var candidateName: String
    /// The owning model's flag, so a report submitted from the call screen
    /// stays confirmed if this sheet is reopened.
    var didSubmit: Bool
    /// Why the last attempt failed, if it did. The form stays up so the
    /// user's words survive and they can retry.
    var failure: String?
    var onSubmit: (ReportReason, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason?
    @State private var details = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    if didSubmit {
                        submitted
                    } else {
                        form
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.md)
            }
            .background(Palette.canvas)
            .navigationTitle("Report \(candidateName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var form: some View {
        Text("What happened?")
            .font(Typography.cardTitle)
            .foregroundStyle(Palette.ink)

        VStack(spacing: Space.xs) {
            ForEach(ReportReason.allCases) { option in
                SelectableCard(
                    title: option.label,
                    isSelected: reason == option
                ) {
                    reason = option
                }
                .accessibilityIdentifier("report.reason.\(option.rawValue)")
            }
        }

        Text("Anything else we should know? (optional)")
            .font(Typography.body)
            .foregroundStyle(Palette.textSecondary)
            .padding(.top, Space.xs)

        MoomoTextEditor(
            placeholder: "Describe what happened…",
            text: $details,
            characterLimit: 500
        )

        if let failure {
            ValidationMessage(message: failure)
                .padding(.top, Space.xs)
        }

        PrimaryButton(title: "Submit report", isEnabled: reason != nil) {
            guard let reason else { return }
            onSubmit(reason, details.isEmpty ? nil : details)
        }
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xl)
        .accessibilityIdentifier("report.submit")
    }

    private var submitted: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(Palette.verifiedGreenFG)
                .padding(.top, Space.xxl)

            Text("Report received")
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.ink)

            Text("Thank you. Our team reviews every report. \(candidateName) won't know you reported them — you can also block them from the call menu.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)

            PrimaryButton(title: "Done") { dismiss() }
                .padding(.top, Space.sm)
                .accessibilityIdentifier("report.done")
        }
        .frame(maxWidth: .infinity)
    }
}
