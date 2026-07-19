import SwiftUI

/// Moomo color tokens.
///
/// Every value is sampled from the supplied reference screens. Do not add a
/// colour here that does not appear in a reference; do not use a raw `Color`
/// literal in a view. If a screen needs a colour that isn't here, it is either
/// a token that needs naming or a mistake.
enum Palette {

    // MARK: - Brand

    /// Deep navy used for headings and primary ink. Sampled from "Hey there"
    /// and "Someone is waiting".
    static let ink = Color(hex: 0x0F1F4B)

    /// Primary interactive blue. Links, active tab, "I'm Interested",
    /// send button, verified badge.
    static let blue = Color(hex: 0x1D4ED8)

    /// Brighter blue used for the outgoing chat bubble fill.
    static let bubbleBlue = Color(hex: 0x7C86E8)

    /// Coral/red call-to-action. "Talk to Him", End Call, "Wants to Talk" bubble.
    static let coral = Color(hex: 0xEF3E56)

    /// Gold. Logo arc, "moomo" wordmark, Premium card accents, call sparkle.
    static let gold = Color(hex: 0xC69B3E)

    /// Lighter gold for the arc gradient's bright end.
    static let goldLight = Color(hex: 0xE3C173)

    /// Dusty rose — the left figure of the M logo.
    static let rose = Color(hex: 0xD4818C)

    /// Coral-pink of the welcome screen's "Verification" CTA, its legal links,
    /// and the active pager dot. Sampled from the phone-auth welcome reference.
    static let flamingo = Color(hex: 0xFA4B64)

    // MARK: - Backgrounds

    /// Warm cream. Live speed-call background.
    static let cream = Color(hex: 0xF8F4F0)

    /// Pale blush pink. Welcome / phone-verification backgrounds, sampled from
    /// the phone-auth welcome reference.
    static let blush = Color(hex: 0xFCF4F5)

    /// Cool off-white. Discover, Decision, Match, Profile backgrounds.
    static let canvas = Color(hex: 0xF7F8FA)

    /// Dark navy. Matchmaking search/connect background, and what the
    /// speed-call video card shows before frames arrive.
    static let night = Color(hex: 0x0A1229)

    /// Slightly lifted navy for call-screen controls.
    static let nightRaised = Color(hex: 0x1B2542)

    /// Card surface.
    static let surface = Color.white

    // MARK: - Text

    static let textPrimary = ink
    static let textSecondary = Color(hex: 0x8A8A8E)
    static let textTertiary = Color(hex: 0xADADB2)
    static let textOnDark = Color.white
    static let textOnDarkSecondary = Color(hex: 0x9AA3BC)

    // MARK: - Status

    static let online = Color(hex: 0x34C759)
    static let verifiedGreenBG = Color(hex: 0xE7F7EC)
    static let verifiedGreenFG = Color(hex: 0x1E8E3E)
    /// Olive-green seal beside the name on the speed-call identity overlay.
    static let verifiedOlive = Color(hex: 0x7E8A50)
    static let notificationDot = Color(hex: 0xFF3B30)

    /// Mascot pink — the ghost sticker on the call screen and the Video Match
    /// tile mascot.
    static let mascotPink = Color(hex: 0xF9A8D4)

    // MARK: - Tints

    /// Pale blue behind icons in stat cards, "Tips" card, completion pill.
    static let blueTint = Color(hex: 0xEEF3FD)

    /// Peach behind the Discover hero and Premium card.
    static let peachTint = Color(hex: 0xFDEDE4)

    static let separator = Color(hex: 0xEDEEF2)
    static let checkboxBorder = Color(hex: 0xC7C7CC)
    static let iconWell = Color(hex: 0xF2F2F5)

    // MARK: - Gradients

    /// Gold arc around the logo — bright at the top-right, deep at the left.
    static let goldArc = LinearGradient(
        colors: [goldLight, gold, Color(hex: 0xB0862F)],
        startPoint: .topTrailing,
        endPoint: .bottomLeading
    )

    /// Discover hero card.
    static let heroPeach = LinearGradient(
        colors: [Color(hex: 0xFDEFE7), Color(hex: 0xFCE7DF)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Video Match card.
    static let videoPink = LinearGradient(
        colors: [Color(hex: 0xFDE8F0), Color(hex: 0xFBD9E8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Real Talk card.
    static let voicePurple = LinearGradient(
        colors: [Color(hex: 0xEDE9FE), Color(hex: 0xE0DBFB)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Premium card.
    static let premiumCream = LinearGradient(
        colors: [Color(hex: 0xFDF3E6), Color(hex: 0xFCEBDA)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Legibility scrim over the bottom of the speed-call video, under the
    /// identity overlay. The reference's photo darkens toward the base; this
    /// guarantees the same on any video frame.
    static let callScrim = LinearGradient(
        stops: [
            .init(color: .clear, location: 0.55),
            .init(color: Color.black.opacity(0.45), location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension Color {
    /// Hex initialiser. `Color(hex: 0x0F1F4B)`.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
