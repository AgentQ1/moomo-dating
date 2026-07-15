import SwiftUI

/// Moomo type scale, read off the reference screens.
///
/// The references use the system face (SF Pro) everywhere except the "moomo"
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
    static let callHeader = Font.system(size: 17, weight: .medium)

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

    /// The "moomo" logotype — a high-contrast didone serif.
    ///
    /// Didot ships with iOS and is by far the closest system face to the
    /// reference: thin hairlines, heavy stems, small round terminals. The
    /// system serif (New York) is a transitional face and reads noticeably
    /// heavier and less elegant, so it is only the fallback.
    static func wordmark(size: CGFloat) -> Font {
        .custom("Didot", size: size)
    }

    // MARK: - Line heights
    //
    // SwiftUI has no direct line-height API; `.lineSpacing` is the *gap*
    // between lines, so these are (target line height − font size).

    /// Tagline and two-line subtitles sit at ~1.35× in the references.
    static let bodyLineSpacing: CGFloat = 5

    /// Chat bubbles run slightly tighter.
    static let messageLineSpacing: CGFloat = 4
}
