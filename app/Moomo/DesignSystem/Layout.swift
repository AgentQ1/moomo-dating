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
    /// The floating self-view on the live call.
    static let localVideo: CGFloat = 18
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
    /// The white icon well at the foot of a chat-mode tile.
    static let chatModeTileIconWell: CGFloat = 44
    /// The hero's top box: orbit rings, orbiting faces, the featured avatar.
    /// Fixed, so nothing drawn inside it can change the card's height.
    static let heroStage: CGFloat = 260
    /// The name line and the line under it, pinned rather than measured. The
    /// card's height is then arithmetic instead of whatever the fonts happen
    /// to render to, which is what lets the skeleton match it exactly.
    static let heroNameLine: CGFloat = 32
    static let heroIdentityLine: CGFloat = 18
    /// Every card that can occupy Discover's hero slot stands exactly this
    /// tall — the skeleton, the loaded hero, and the "no one's around" card
    /// alike — so the feed arriving swaps the card's contents without
    /// resizing the card or moving the chat-mode tiles below it.
    ///
    /// `Space.lg + heroStage + Space.md + heroNameLine + Space.xxs
    ///  + heroIdentityLine + Space.md + primaryCTAHeight + Space.lg`.
    static let heroCardHeight: CGFloat = 450
    /// The white location pill above the hero.
    static let locationBarHeight: CGFloat = 56

    // Call
    /// Every floating in-call control is this size, End Call included. One
    /// diameter for the row means no control is the odd one out to hit, and
    /// nothing can resize mid-call.
    static let callFloatingControl: CGFloat = 62
    /// The smaller discs in the call's top corners (minimise, safety menu).
    static let callChromeButton: CGFloat = 40
    /// The self-view that floats over the remote video, and may be dragged.
    static let localVideoWidth: CGFloat = 100
    static let localVideoHeight: CGFloat = 140
    /// The avatar shown on the dark ground while the remote camera has not
    /// produced a frame yet. Modest on purpose — the call screen is the other
    /// person's face, not a profile card.
    static let callWaitingAvatar: CGFloat = 132
    /// Reserved at the top of the call for the title, the countdown, and the
    /// two corner buttons. The dragged self-view may not enter it, so a
    /// parked thumbnail can never cover the clock.
    static let callHeaderBand: CGFloat = 84
    /// Reserved at the bottom of the call for the floating controls. Held
    /// constant, and off limits to the self-view and to any card an in-call
    /// experience puts up, so End Call is never covered or moved.
    static let callControlsBand: CGFloat = 96
    /// The band above the controls where a transport failure or a Go Play
    /// notice is written. Always reserved, so a line arriving mid-call never
    /// moves the controls.
    static let callMessageSlot: CGFloat = 32

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

/// The sign-in screen's geometry, measured off tools/visual/reference/welcome.png.
///
/// Every `y` is an absolute distance from the top of the display — the same
/// origin the reference's own pixels use — so the screen is assembled by
/// placing blocks at coordinates rather than by accumulating paddings, and a
/// correction to one block cannot shift the ones under it.
///
/// The reference is 863 × 1822 px. It is a design export, not a device
/// capture: its aspect matches no iPhone, and its status bar and home
/// indicator are drawn art sitting a few points off where iOS puts the real
/// ones. Pixels convert at 402/863 across and 874/1822 down, which is what
/// `tools/visual/compare.py` normalises a 402 × 874 capture back to.
enum WelcomeMetrics {

    /// The design's own screen box. Positions below are absolute inside it.
    static let designWidth: CGFloat = 402
    static let designHeight: CGFloat = 874

    // MARK: - Top bar

    /// "Trouble logging in?" — its baseline, and its inset from the right edge.
    static let helpLinkBaseline: CGFloat = 76.42
    static let helpLinkTrailing: CGFloat = 15.5

    // MARK: - Avatar cluster

    /// Outer diameter including the white ring.
    ///
    /// A true circle cannot match the reference on both axes at once: the
    /// reference's circles measure 151.3 x 154.0 of its own pixels, an ellipse
    /// 1.8% taller than wide, because the export is stretched vertically
    /// relative to any device. Splitting that error evenly across all four
    /// edges was tried and measured a point worse than this, which matches the
    /// width exactly and leaves the whole discrepancy on the top and bottom
    /// arcs — the shorter run of the two.
    static let avatarOuter: CGFloat = 70.48
    /// The white ring, drawn outside the photo rather than over it.
    static let avatarRing: CGFloat = 2.6
    static var avatarPhoto: CGFloat { avatarOuter - avatarRing * 2 }
    /// Centre-to-centre. The circles overlap by `avatarOuter - avatarSpacing`.
    static let avatarSpacing: CGFloat = 61.78
    /// Centre line of the row of four.
    static let avatarCentreY: CGFloat = 190.97

    /// How each photograph is framed inside its circle.
    ///
    /// The stored assets are not cut to the reference's circles — they carry a
    /// little more around the subject — so filling the circle with them
    /// straight leaves every face a few percent small and slightly off. These
    /// are the zoom and nudge that register each asset against the reference,
    /// found by maximising normalised cross-correlation against the reference's
    /// own pixels. Nothing about the images themselves is altered.
    struct AvatarCrop {
        let asset: String
        let zoom: CGFloat
        let shift: CGSize
    }

    static let avatarCrops: [AvatarCrop] = [
        AvatarCrop(asset: "welcome-avatar-1", zoom: 1.052, shift: CGSize(width: 0.47, height: 0.47)),
        AvatarCrop(asset: "welcome-avatar-2", zoom: 1.048, shift: CGSize(width: -0.93, height: -0.47)),
        AvatarCrop(asset: "welcome-avatar-3", zoom: 1.043, shift: CGSize(width: 1.86, height: 0.93)),
        // The one asset supplied at full resolution rather than cut from a
        // screen, so its framing differs most.
        AvatarCrop(asset: "welcome-avatar-4", zoom: 1.135, shift: CGSize(width: 3.26, height: 14.44)),
    ]

    // MARK: - Headline

    /// The two lines' baselines, each set independently rather than by line
    /// spacing — the reference's 38.4pt baseline gap is tighter than Didot's
    /// natural line, and a negative `lineSpacing` is not a thing to rely on.
    ///
    /// Both sit 3pt above the reference's own baselines, on purpose. The
    /// reference is a design export stretched ~5% taller than a device, so its
    /// glyphs stand taller than any font can here; sitting the type on the
    /// same baseline would pile the whole error onto the cap line. Three
    /// points up centres the ink instead, which measured 1.1pp better across
    /// the headline box.
    static let headlineFirstBaseline: CGFloat = 291.8
    static let headlineSecondBaseline: CGFloat = 330.2

    // MARK: - Phone row

    /// Left and right insets shared by the phone row, its rule, and the CTA.
    static let fieldInset: CGFloat = 28.5
    /// The row of controls above the rule.
    static let phoneRowTop: CGFloat = 385.25
    static let phoneRowHeight: CGFloat = 30.7
    /// The row's controls sit a hair inside the rule beneath them.
    static let phoneRowX: CGFloat = 0.54
    /// Positions inside the row, measured from its own leading edge (that is,
    /// absolute x minus `fieldInset`). The row is laid out by coordinate like
    /// the rest of the screen, because glyph side bearings make an `HStack`
    /// spacing and a measured ink gap two different numbers.
    /// The "+1" is not flush with the row's edge: the reference sets its ink
    /// 1.54pt further in than the rule below starts.
    static let dialCodeX: CGFloat = 1.54
    static let dialCodeChevronGap: CGFloat = 5.35
    static let dividerX: CGFloat = 55.85
    static let fieldIconX: CGFloat = 75.53
    static let numberFieldX: CGFloat = 106.68

    /// The reference does not sit the row's parts on one centre line: the dial
    /// code, its chevron, the rule and the receiver all ride about 1.3pt above
    /// where the placeholder's line box centres them.
    static let dialCodeY: CGFloat = -1.4
    static let dividerY: CGFloat = -1.58
    static let fieldIconY: CGFloat = -1.15
    /// The number field runs to the row's trailing edge.
    static var numberFieldWidth: CGFloat {
        designWidth - fieldInset * 2 - numberFieldX
    }
    /// The rule under the row: 1pt, centred on this line.
    static let hairlineCentreY: CGFloat = 427.89
    /// Where an inline error is written, in the gap the reference leaves empty
    /// between the rule and the CTA. Fixed, so a message appearing moves
    /// nothing.
    static let errorTop: CGFloat = 431

    // MARK: - Verification CTA

    static let ctaTop: CGFloat = 455.25
    static let ctaHeight: CGFloat = 58.5
    /// `HStack` spacing between the phone glyph and the word "Verification".
    /// Smaller than the 14.9pt the reference measures ink-to-ink, because the
    /// symbol's frame is wider than the glyph it draws.
    static let ctaIconToLabel: CGFloat = 9.9
    /// The glyph and label together sit left of the capsule's centre, as the
    /// reference sets them.
    static let ctaContentOffset = CGSize(width: -3.5, height: 0.5)

    // MARK: - Consent

    static let consentCheckboxCentre = CGPoint(x: 40.99, y: 551.64)
    static let consentCheckboxDiameter: CGFloat = 23.6
    static let consentCheckboxStroke: CGFloat = 1.4
    /// Left edge of the sentence, and the width that reproduces the
    /// reference's three line breaks (valid anywhere in 282…294).
    static let consentTextLeading: CGFloat = 65.18
    static let consentTextWidth: CGFloat = 288
    /// Baseline of "I have read and agree to the…".
    static let consentFirstBaseline: CGFloat = 554.73
    /// How far the checkbox's centre sits above that baseline.
    static let consentCheckboxRise: CGFloat = 2.59

    // MARK: - Skyline

    /// The artwork band. Full-bleed horizontally.
    static let skylineTop: CGFloat = 618.09
    static let skylineHeight: CGFloat = 221.62

    // MARK: - Pager

    static let pagerCentreY: CGFloat = 830.83
    static let pagerCount = 7
    static let pagerActiveIndex = 3
    /// Centre-to-centre, held by fixed-width cells so the wider active mark
    /// does not push its neighbours.
    static let pagerPitch: CGFloat = 16.615
    static let pagerDotDiameter: CGFloat = 6.2
    /// Corner-to-corner across the active diamond's bounding box. The rounded
    /// corners eat into the points, so the square behind it is sized from this
    /// rather than the other way round.
    static let pagerActiveDiagonal: CGFloat = 11.85
    static let pagerActiveCornerRadius: CGFloat = 1.88

    // MARK: - Background sketches

    /// Outlined triangle, top left. Equilateral, rotated off-axis.
    static let sketchTriangleCentre = CGPoint(x: 72.7, y: 129.15)
    static let sketchTriangleRadius: CGFloat = 23.2
    static let sketchTriangleRotation: Angle = .degrees(-12.5)
    static let sketchTriangleStroke: CGFloat = 1.2
    /// The cross on the right.
    static let sketchCrossCentre = CGPoint(x: 345.85, y: 241.56)
    static let sketchCrossSize: CGFloat = 36.6
    static let sketchCrossStroke: CGFloat = 1.4
    /// The two four-point sparkles.
    static let sketchSparkleLeftCentre = CGPoint(x: 34.70, y: 175.57)
    static let sketchSparkleRightCentre = CGPoint(x: 368.69, y: 214.42)
    static let sketchSparkleSize: CGFloat = 7.8
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
