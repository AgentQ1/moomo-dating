import SwiftUI

/// The consent gate on the welcome screen: a circular checkbox beside wrapping
/// text with "Privacy Policy" and "Terms of Service" as pink links, plus the
/// under-18 prohibition sentence. Geometry is measured off
/// `tools/visual/reference/welcome.png` — see `WelcomeMetrics`.
///
/// The checkbox and the links are separately tappable — tapping the sentence
/// toggles consent, tapping a link opens the document. That distinction matters
/// legally: consent must be a deliberate act, not a side effect of reading.
struct ConsentRow: View {
    @Binding var isChecked: Bool
    var onOpenPrivacy: () -> Void
    var onOpenTerms: () -> Void

    /// Left edge of the ring, and the gap from the ring to the sentence.
    private var checkboxLeading: CGFloat {
        WelcomeMetrics.consentCheckboxCentre.x - WelcomeMetrics.consentCheckboxDiameter / 2
    }
    private var ringToText: CGFloat {
        WelcomeMetrics.consentTextLeading
            - WelcomeMetrics.consentCheckboxCentre.x
            - WelcomeMetrics.consentCheckboxDiameter / 2
    }

    var body: some View {
        // Baseline-aligned rather than top-aligned: the reference sets the
        // ring's centre a few points above the first line's baseline, which is
        // a relationship between the ring and the type, not between two boxes.
        HStack(alignment: .firstTextBaseline, spacing: ringToText) {
            checkbox
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions.height / 2 + WelcomeMetrics.consentCheckboxRise
                }

            text
        }
        .padding(.leading, checkboxLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var checkbox: some View {
        Button {
            isChecked.toggle()
        } label: {
            Circle()
                .fill(isChecked ? Palette.verificationMagenta : Color.clear)
                .overlay(
                    Circle()
                        .strokeBorder(
                            isChecked ? Palette.verificationMagenta : Palette.welcomeCheckboxStroke,
                            lineWidth: WelcomeMetrics.consentCheckboxStroke
                        )
                )
                .overlay {
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(
                    width: WelcomeMetrics.consentCheckboxDiameter,
                    height: WelcomeMetrics.consentCheckboxDiameter
                )
                // The ring is smaller than a comfortable target, so the tap
                // area is grown around it without moving the drawn circle.
                .contentShape(
                    Rectangle().size(
                        width: Size.minTapTarget,
                        height: Size.minTapTarget
                    ).offset(
                        x: (WelcomeMetrics.consentCheckboxDiameter - Size.minTapTarget) / 2,
                        y: (WelcomeMetrics.consentCheckboxDiameter - Size.minTapTarget) / 2
                    )
                )
        }
        .buttonStyle(.plain)
        .animation(Motion.tap, value: isChecked)
        .accessibilityLabel("I have read and agree to the Privacy Policy and Terms of Service")
        .accessibilityAddTraits(isChecked ? [.isSelected] : [])
    }

    /// Built as one wrapping paragraph so the links flow inline exactly as in
    /// the reference. The width is pinned rather than left to the container:
    /// the reference breaks after "Terms" and after "are", which only happens
    /// in a 282–294pt column.
    private var text: some View {
        Text(attributed)
            .font(Typography.welcomeConsent)
            .lineSpacing(Typography.welcomeConsentLineSpacing)
            .tint(Palette.legalLink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: WelcomeMetrics.consentTextWidth, alignment: .leading)
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
    ///
    /// The scheme is unregistered and matched by identity right here, so it is
    /// a private sentinel rather than a real URL — but iOS shows it verbatim
    /// in the link preview on a long press, which makes it one of the few
    /// places the retired "moomo" name could still reach a user's eyes. It
    /// carries the store name for that reason alone.
    private static let privacyURL = URL(string: "baybe://legal/privacy")!
    private static let termsURL = URL(string: "baybe://legal/terms")!

    private var attributed: AttributedString {
        var result = AttributedString("I have read and agree to the ")
        result.foregroundColor = Palette.welcomeInk

        var privacy = AttributedString("Privacy Policy")
        privacy.foregroundColor = Palette.legalLink
        privacy.link = Self.privacyURL

        var conjunction = AttributedString(" and ")
        conjunction.foregroundColor = Palette.welcomeInk

        // The full stop is outside the link run: the reference sets "Terms of
        // Service" pink and the stop after it navy.
        var terms = AttributedString("Terms of Service")
        terms.foregroundColor = Palette.legalLink
        terms.link = Self.termsURL

        var underage = AttributedString(
            ". I understand that users under 18 are prohibited from registering and using the platform."
        )
        underage.foregroundColor = Palette.welcomeInk

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
            }
        }
    }
    return Harness()
}
