import SwiftUI

/// The consent gate on the welcome screen: a circular checkbox beside wrapping
/// text with "Privacy Policy" and "Terms of Service" as coral links, plus the
/// under-18 prohibition sentence. Matches the phone-auth welcome reference.
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
            Circle()
                .fill(isChecked ? Palette.flamingo : Color.clear)
                .overlay(
                    Circle()
                        .stroke(
                            isChecked ? Palette.flamingo : Palette.ink.opacity(0.5),
                            lineWidth: 1.5
                        )
                )
                .overlay {
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .frame(width: Size.minTapTarget, height: Size.minTapTarget, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24, alignment: .topLeading)
        .animation(Motion.tap, value: isChecked)
        .accessibilityLabel("I have read and agree to the Privacy Policy and Terms of Service")
        .accessibilityAddTraits(isChecked ? [.isSelected] : [])
    }

    /// Built as one wrapping paragraph so the links flow inline exactly as in
    /// the reference.
    private var text: some View {
        Text(attributed)
            .font(.system(size: 14))
            .lineSpacing(4)
            .tint(Palette.flamingo)
            // Without this the sentence truncates to a single line inside the
            // HStack instead of wrapping as the reference does.
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
        result.foregroundColor = Palette.ink

        var privacy = AttributedString("Privacy Policy")
        privacy.foregroundColor = Palette.flamingo
        privacy.link = Self.privacyURL

        var conjunction = AttributedString(" and ")
        conjunction.foregroundColor = Palette.ink

        // The full stop is part of the link run in the reference.
        var terms = AttributedString("Terms of Service.")
        terms.foregroundColor = Palette.flamingo
        terms.link = Self.termsURL

        var underage = AttributedString(
            " I understand that users under 18 are prohibited from registering and using the platform."
        )
        underage.foregroundColor = Palette.ink

        result.append(privacy)
        result.append(conjunction)
        result.append(terms)
        result.append(underage)
        return result
    }
}

#Preview {
    struct Harness: View {
        @State private var checked = false
        var body: some View {
            ZStack {
                Palette.blush.ignoresSafeArea()
                ConsentRow(isChecked: $checked, onOpenPrivacy: {}, onOpenTerms: {})
                    .padding(.horizontal, Space.gutter)
            }
        }
    }
    return Harness()
}
