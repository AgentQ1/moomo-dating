import SwiftUI

/// Spacing scale. The references sit on a 4pt grid with 20pt screen gutters.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 40

    /// Horizontal screen gutter. Every reference screen uses this.
    static let gutter: CGFloat = 20

    /// Gap between stacked cards in a list (auth buttons, menu cards).
    static let cardGap: CGFloat = 14

    /// Gap between the two chat-mode cards.
    static let tileGap: CGFloat = 12
}

/// Corner radii.
enum Radius {
    /// Chat-mode tiles, stat cards.
    static let tile: CGFloat = 18
    /// Standard card: auth buttons, decision cards, menu card.
    static let card: CGFloat = 20
    /// Large card: Discover hero, Tips card, Premium card.
    static let cardLarge: CGFloat = 24
    /// Floating tab bar.
    static let tabBar: CGFloat = 24
    /// Icon wells and small containers.
    static let well: CGFloat = 14
    /// Consent checkbox.
    static let checkbox: CGFloat = 6
    /// Chat bubble.
    static let bubble: CGFloat = 18
    /// Self-view preview in the corner of the speed-call video card.
    static let localVideo: CGFloat = 14
    /// The speed-call video card.
    static let callCard: CGFloat = 28
    /// Fully rounded — use `.capsule` shapes instead where possible.
    static let pill: CGFloat = 999
}

/// Fixed component dimensions taken from the references.
enum Size {
    // Auth
    static let authButtonHeight: CGFloat = 60
    static let authIconWell: CGFloat = 44
    static let checkbox: CGFloat = 28
    /// 0.68 × the 402pt screen width, per the reference.
    static let logoDiameter: CGFloat = 274

    // Discover
    static let heroAvatar: CGFloat = 200
    static let orbitAvatar: CGFloat = 64
    static let primaryCTAHeight: CGFloat = 64
    static let topActionButton: CGFloat = 52
    static let chatModeTileHeight: CGFloat = 200

    // Call
    static let callSecondaryControl: CGFloat = 64
    static let callEndControl: CGFloat = 76
    static let localVideoWidth: CGFloat = 92
    static let localVideoHeight: CGFloat = 120

    // Decision / Match
    static let decisionAvatar: CGFloat = 110
    static let decisionCardHeight: CGFloat = 84

    // Chat
    static let chatAvatar: CGFloat = 44
    static let sendButton: CGFloat = 44
    static let inputBarHeight: CGFloat = 56

    // Profile
    static let profileAvatar: CGFloat = 96
    static let statCardHeight: CGFloat = 110
    static let menuRowHeight: CGFloat = 60

    // Tab bar
    static let tabBarHeight: CGFloat = 68
    static let tabIcon: CGFloat = 24

    // Icons
    static let iconSmall: CGFloat = 16
    static let iconMedium: CGFloat = 22
    static let iconLarge: CGFloat = 28

    /// Minimum tappable area. Anything interactive smaller than this needs a
    /// `.contentShape` expansion.
    static let minTapTarget: CGFloat = 44
}

/// Shadows. The references use wide, very soft, low-opacity shadows —
/// never the SwiftUI default.
struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum Shadows {
    /// Auth buttons, stat cards, menu card — barely-there lift.
    static let card = ShadowStyle(
        color: Color(hex: 0x0F1F4B, alpha: 0.05), radius: 12, x: 0, y: 4
    )

    /// Discover hero, Tips card.
    static let cardLarge = ShadowStyle(
        color: Color(hex: 0x0F1F4B, alpha: 0.06), radius: 20, x: 0, y: 8
    )

    /// Floating tab bar.
    static let tabBar = ShadowStyle(
        color: Color(hex: 0x0F1F4B, alpha: 0.08), radius: 24, x: 0, y: 8
    )

    /// Coral CTA — tinted, not neutral.
    static let coralCTA = ShadowStyle(
        color: Color(hex: 0xEF3E56, alpha: 0.32), radius: 18, x: 0, y: 8
    )

    /// Warm peach halo around the speed-call video card.
    static let callCard = ShadowStyle(
        color: Color(hex: 0xF2B48C, alpha: 0.45), radius: 26, x: 0, y: 8
    )

    /// Avatars with a white ring.
    static let avatar = ShadowStyle(
        color: Color(hex: 0x0F1F4B, alpha: 0.10), radius: 16, x: 0, y: 6
    )
}

extension View {
    /// Apply a design-system shadow.
    func shadow(_ style: ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}

/// Animation timings. Kept in one place so motion feels consistent.
enum Motion {
    /// Button press / tap feedback.
    static let tap = Animation.spring(response: 0.28, dampingFraction: 0.7)
    /// Screen-level content transitions.
    static let transition = Animation.easeInOut(duration: 0.3)
    /// Slow ambient loops: orbit rings, searching pulse, logo arc.
    static let ambient = Animation.easeInOut(duration: 2.4).repeatForever(autoreverses: true)
    /// Typing-indicator dots.
    static let typingDot = Animation.easeInOut(duration: 0.6).repeatForever()
    /// Celebration on match.
    static let celebrate = Animation.spring(response: 0.5, dampingFraction: 0.6)

    /// Pressed-state scale for tappable cards and buttons.
    static let pressedScale: CGFloat = 0.97
}
