import SwiftUI

/// The consent gate on the welcome screen: a square checkbox beside wrapping
/// text with "Privacy Policy" and "Terms of Service" as blue links.
///
/// The checkbox and the links are separately tappable — tapping the sentence
/// toggles consent, tapping a link opens the document. That distinction matters
/// legally: consent must be a deliberate act, not a side effect of reading.
struct ConsentRow: View {
    @Binding var isChecked: Bool
    var onOpenPrivacy: () -> Void
    var onOpenTerms: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            checkbox

            text
                .padding(.top, 2)
        }
    }

    private var checkbox: some View {
        Button {
            isChecked.toggle()
        } label: {
            RoundedRectangle(cornerRadius: Radius.checkbox, style: .continuous)
                .fill(isChecked ? Palette.blue : Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.checkbox, style: .continuous)
                        .stroke(isChecked ? Palette.blue : Palette.checkboxBorder, lineWidth: 1.5)
                )
                .overlay {
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: Size.checkbox, height: Size.checkbox)
                .contentShape(Rectangle())
                .frame(width: Size.minTapTarget, height: Size.minTapTarget, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Size.checkbox, height: Size.checkbox, alignment: .topLeading)
        .animation(Motion.tap, value: isChecked)
        .accessibilityLabel("I have read and agree to the Privacy Policy and Terms of Service")
        .accessibilityAddTraits(isChecked ? [.isSelected] : [])
    }

    /// Built as one wrapping paragraph so the links flow inline exactly as in
    /// the reference, where "Terms" and "of Service" break across lines.
    private var text: some View {
        Text(attributed)
            .font(Typography.body)
            .lineSpacing(Typography.bodyLineSpacing)
            .tint(Palette.blue)
            // Without this the sentence truncates to a single line inside the
            // HStack instead of wrapping after "and", as the reference does.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                switch url {
                case Self.privacyURL: onOpenPrivacy()
                case Self.termsURL: onOpenTerms()
                default: return .systemAction
                }
                return .handled
            })
    }

    /// In-app link targets. These are intercepted by `openURL` above and never
    /// reach the system, so the documents open in-app rather than in Safari.
    private static let privacyURL = URL(string: "moomo://legal/privacy")!
    private static let termsURL = URL(string: "moomo://legal/terms")!

    private var attributed: AttributedString {
        var result = AttributedString("I have read and agree to the ")
        result.foregroundColor = Palette.textPrimary

        var privacy = AttributedString("Privacy Policy")
        privacy.foregroundColor = Palette.blue
        privacy.link = Self.privacyURL

        var conjunction = AttributedString(" and ")
        conjunction.foregroundColor = Palette.textPrimary

        var terms = AttributedString("Terms of Service")
        terms.foregroundColor = Palette.blue
        terms.link = Self.termsURL

        result.append(privacy)
        result.append(conjunction)
        result.append(terms)
        return result
    }
}

#Preview {
    struct Harness: View {
        @State private var checked = false
        var body: some View {
            ZStack {
                Palette.cream.ignoresSafeArea()
                ConsentRow(isChecked: $checked, onOpenPrivacy: {}, onOpenTerms: {})
                    .padding(.horizontal, Space.gutter)
            }
        }
    }
    return Harness()
}
