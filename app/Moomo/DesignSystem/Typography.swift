import SwiftUI

/// Baybe type scale, read off the reference screens.
///
/// The references use the system face (SF Pro) everywhere except the "baybe"
/// wordmark, which is a high-contrast serif. Sizes are fixed rather than
/// `.largeTitle` etc. because the references don't line up with Apple's
/// default scale — `screenTitle` is 34/40, which no system style matches.
enum Typography {

    // MARK: - Display / titles

    /// "Hey there 👋", "Your Profile", "Call ended!", "It's a Match!"
    static let screenTitle = Font.system(size: 34, weight: .bold)

    /// "Someone is waiting"
    static let heroTitle = Font.system(size: 26, weight: .bold)

    /// "02:45" call timer.
    static let timer = Font.system(size: 44, weight: .regular).monospacedDigit()

    /// Stat numbers: 12 / 8 / 5.
    static let statNumber = Font.system(size: 28, weight: .bold)

    // MARK: - Body

    /// Card titles: "Video Match", "I'm Interested", "Premium",
    /// "Tips for better matches".
    static let cardTitle = Font.system(size: 19, weight: .semibold)

    /// Menu rows: "Edit Profile", and auth button labels.
    static let rowTitle = Font.system(size: 17, weight: .medium)

    /// Tips rows: "Be real & authentic".
    static let rowTitleSmall = Font.system(size: 16, weight: .semibold)

    /// Tagline, subtitles, chat text, "Start a voice chat…".
    static let body = Font.system(size: 15, weight: .regular)

    /// "You both have 24 hours to decide." — the bold run.
    static let bodyEmphasis = Font.system(size: 15, weight: .semibold)

    /// Chat message text.
    static let message = Font.system(size: 16, weight: .regular)

    /// "3-Minute Speed Call" header.
    static let callHeader = Font.system(size: 17, weight: .semibold)

    /// "Time left 02:39" under the call header. Monospaced digits so the
    /// countdown doesn't jitter.
    static let callSubtitle = Font.system(size: 13, weight: .regular).monospacedDigit()

    /// "Marketing Student" / "London, UK" rows on the call identity overlay.
    static let callDetail = Font.system(size: 14, weight: .medium)

    /// "Mute" / "End Call" / "Camera" under the call controls.
    static let callControlLabel = Font.system(size: 13, weight: .medium)

    // MARK: - Small

    /// "CHAT MODES" section label. Apply `.tracking(Typography.sectionTracking)`.
    static let sectionLabel = Font.system(size: 13, weight: .bold)
    static let sectionTracking: CGFloat = 0.8

    /// Tab bar labels, "Mute" / "End Call" / "Flip", stat labels.
    static let caption = Font.system(size: 12, weight: .medium)

    /// Chat timestamps.
    static let timestamp = Font.system(size: 12, weight: .regular)

    /// Pills: "Lv. 1", "Verified", "Earn rewards".
    static let pill = Font.system(size: 13, weight: .semibold)

    /// "Wants to Talk to You" speech bubble.
    static let speechBubble = Font.system(size: 13, weight: .bold)

    // MARK: - Wordmark

    /// The "baybe" logotype — a high-contrast didone serif. (The reference
    /// screens this scale was measured from still carry the retired "moomo"
    /// wordmark; the shipped mark renders "baybe" — see `MoomoLogo`.)
    ///
    /// Didot ships with iOS and is by far the closest system face to the
    /// reference: thin hairlines, heavy stems, small round terminals. The
    /// system serif (New York) is a transitional face and reads noticeably
    /// heavier and less elegant, so it is only the fallback.
    static func wordmark(size: CGFloat) -> Font {
        .custom("Didot", size: size)
    }

    // MARK: - Welcome / sign-in
    //
    // Sizes are fitted, not chosen: each is the point size whose rendered ink
    // width matches the corresponding run in tools/visual/reference/welcome.png
    // to within a quarter-point. `fixedSize` throughout, because the screen is
    // laid out against measured pixel positions and Dynamic Type resizing the
    // headline would slide everything under it.

    /// "Find the person nearby / you\u{2019}d most like to meet".
    ///
    /// Didot, at the size whose rendered line width matches the reference's
    /// first line. The reference's face is not a system font, so this is a
    /// question of which didone iOS ships lands closest, and it was settled by
    /// rendering thirteen candidates at reference scale and scoring each
    /// against the reference's own pixels: Didot wins at 13.7% of the headline
    /// box differing, against 14.6% for Didot Bold, 15.3% for Baskerville and
    /// Hoefler Text, and 15.6% for Bodoni 72 — which matches the reference's
    /// stem weight exactly but sets far wider letterforms. Tracking was swept
    /// too and bought 0.1pp, which is not worth a headline that no longer sets
    /// at its natural width.
    ///
    /// The residual is letterform shape, and it cannot be removed without the
    /// original face.
    static let welcomeHeadline = Font.custom("Didot", fixedSize: 28.4)

    /// "Trouble logging in?"
    static let welcomeHelpLink = Font.system(size: 14.2, weight: .regular)

    /// The "+1" dial code.
    static let welcomeDialCode = Font.system(size: 19.4, weight: .semibold)

    /// "Enter phone number".
    static let welcomePhoneField = Font.system(size: 16.8, weight: .regular)

    /// The "Verification" capsule's label.
    static let welcomeCTA = Font.system(size: 16.8, weight: .semibold)

    /// The consent sentence.
    static let welcomeConsent = Font.system(size: 11, weight: .regular)

    /// The consent block's baselines are 21.0pt apart against a 12.95pt line.
    /// Both the size and this gap were swept offline against the reference's
    /// own pixels; 11pt on a 21pt rhythm is the minimum.
    static let welcomeConsentLineSpacing: CGFloat = 8.05

    // MARK: - Line heights
    //
    // SwiftUI has no direct line-height API; `.lineSpacing` is the *gap*
    // between lines, so these are (target line height − font size).

    /// Tagline and two-line subtitles sit at ~1.35× in the references.
    static let bodyLineSpacing: CGFloat = 5

    /// Chat bubbles run slightly tighter.
    static let messageLineSpacing: CGFloat = 4
}
