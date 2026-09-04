import SwiftUI
import XCTest
@testable import Moomo

/// Discover must not change shape once it is on screen.
///
/// The feed arrives a beat after the screen does, so Discover renders twice:
/// once with the placeholder card, once with whatever the feed turned out to
/// be. If those two cards are not the same size, the second render moves the
/// chat-mode tiles and everything else below them — the blink.
///
/// These measure the real SwiftUI layout rather than asserting on constants:
/// a hosting controller is asked what each card wants to be at Discover's own
/// width, which is exactly the question the screen asks it.
@MainActor
final class DiscoverLayoutStabilityTests: XCTestCase {

    /// The hero slot's width on a 402pt phone, gutters removed.
    private let cardWidth: CGFloat = 402 - Space.gutter * 2

    private let kenji = DiscoveryCandidate(
        id: "u-featured", displayName: "Kenji", age: 26, city: "Chicago",
        photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .he
    )

    /// What the view asks to be, given a width and all the height it likes.
    private func height(_ view: some View, width: CGFloat) -> CGFloat {
        let controller = UIHostingController(rootView: view)
        let fitted = controller.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return fitted.height
    }

    // MARK: - The hero slot

    /// The one that used to be wrong: the skeleton was about fifty points
    /// shorter than the hero, so the feed landing shunted the whole screen.
    func testTheSkeletonIsTheSameHeightAsTheHeroItStandsInFor() {
        let skeleton = height(HeroSkeleton(), width: cardWidth)
        let hero = height(
            HeroCard(featured: kenji, nearby: DiscoveryState.sample.nearby, onTalk: {}),
            width: cardWidth
        )

        XCTAssertEqual(
            skeleton, hero, accuracy: 0.5,
            "Loading → loaded must not change the hero slot's height"
        )
        XCTAssertEqual(
            hero, Size.heroCardHeight, accuracy: 0.5,
            "The hero must be exactly the height the design system reserves for it"
        )
    }

    /// The other way Discover's first render can end: an empty pool. It is
    /// reached from the same skeleton, so it has to be the same size too.
    func testTheNoOneAroundCardIsTheSameHeightAsTheHero() {
        let card = height(
            DiscoverMessageCard(
                icon: "person.2.slash",
                title: "No one's around",
                message: "Nobody's waiting right now. Tap Nearby and we'll pair you with the first person who's free.",
                actionTitle: "Nearby",
                action: {}
            ),
            width: cardWidth
        )

        XCTAssertEqual(
            card, height(HeroSkeleton(), width: cardWidth), accuracy: 0.5,
            "Loading → no one's around must not change the hero slot's height"
        )
    }

    /// Every failure state lands in the same slot, and none of them may
    /// resize it. The offline card's copy is the longest of them.
    func testEveryMessageCardKeepsTheHeroSlotsHeight() {
        for error in [DiscoveryError.offline, .rateLimited, .sessionExpired, .loadFailed(code: "unauthenticated")] {
            let card = height(
                DiscoverMessageCard(
                    icon: "wifi.slash",
                    title: "Something went wrong",
                    message: error.errorDescription ?? "",
                    actionTitle: "Try again",
                    action: {}
                ),
                width: cardWidth
            )
            XCTAssertEqual(
                card, Size.heroCardHeight, accuracy: 0.5,
                "The \(error) card must not resize the hero slot"
            )
        }
    }

    /// The hero's own copy varies — a city, "Online now", or neither, in
    /// which case the line falls back to longer sales copy. None of it may
    /// change how tall the card is.
    func testTheHeroIsOneHeightWhateverItHasToSay() {
        let anonymous = DiscoveryCandidate(
            id: "u-2", displayName: "Alexandrina", age: 31, city: "",
            photoPath: nil, isOnline: false, wantsToTalk: false, pronoun: .they
        )

        XCTAssertEqual(
            height(HeroCard(featured: anonymous, nearby: [], onTalk: {}), width: cardWidth),
            height(
                HeroCard(featured: kenji, nearby: DiscoveryState.sample.nearby, onTalk: {}),
                width: cardWidth
            ),
            accuracy: 0.5,
            "A hero with no city and no orbit must be the same height as a full one"
        )
    }

    // MARK: - The chat-mode tiles

    /// The two tiles sit side by side, so a difference between them is
    /// visible as a step in the row.
    func testTheTwoChatModeTilesAreTheSameHeight() {
        let tileWidth = (cardWidth - Space.tileGap) / 2

        let videoMatch = height(
            ChatModeTile(
                title: "Video Match",
                subtitle: "Instant video conversations",
                icon: "video.fill",
                iconColor: Palette.mascotPinkInk,
                gradient: Palette.videoPink,
                mascotColor: Palette.mascotPink,
                action: {}
            ),
            width: tileWidth
        )
        let goPlay = height(
            ChatModeTile(
                title: "Go Play",
                subtitle: "Match, talk, then pick a game.",
                icon: "gamecontroller.fill",
                iconColor: Palette.mascotSageInk,
                gradient: Palette.goPlaySage,
                mascotColor: Palette.mascotSage,
                action: {}
            ),
            width: tileWidth
        )

        XCTAssertEqual(videoMatch, goPlay, accuracy: 0.5, "The two tiles must match")
        XCTAssertEqual(
            videoMatch, Size.chatModeTileHeight, accuracy: 0.5,
            "A tile is a fixed height, whatever its copy measures to"
        )
    }

    /// Copy long enough to wrap must not push a tile taller. The subtitle
    /// reserves its two lines, so this is the same tile either way.
    func testALongSubtitleDoesNotGrowTheTile() {
        let tileWidth = (cardWidth - Space.tileGap) / 2
        let tile = ChatModeTile(
            title: "Go Play",
            subtitle: "Match, talk, and then pick something to play together right now",
            icon: "gamecontroller.fill",
            iconColor: Palette.mascotSageInk,
            gradient: Palette.goPlaySage,
            mascotColor: Palette.mascotSage,
            action: {}
        )

        XCTAssertEqual(
            height(tile, width: tileWidth), Size.chatModeTileHeight, accuracy: 0.5,
            "A tile's height is its own, not its copy's"
        )
    }

    // MARK: - The call screen's controls

    /// The floating controls band is big enough for the controls that float
    /// in it. There is one circle size now and no compact variant, so this is
    /// the whole of the arithmetic — but it is arithmetic the self-view and
    /// the in-call cards both budget against, and if the band ever shrank
    /// below the circles the two would start overlapping End Call.
    func testTheControlsBandFitsTheFloatingControls() {
        XCTAssertGreaterThanOrEqual(
            Size.callControlsBand, Size.callFloatingControl,
            "The reserved band must fit the controls that float in it"
        )
        XCTAssertGreaterThanOrEqual(
            Size.callHeaderBand, Size.callChromeButton,
            "The reserved header band must fit the corner buttons"
        )
    }

    /// The draggable self-view cannot be parked on top of the countdown or on
    /// top of End Call. Its legal region is the video minus the two reserved
    /// bands, and on the shortest screen the app supports that region still
    /// has to exist — a `min > max` clamp would pin the tile to a single
    /// point, which is a bug the user would read as "it stopped dragging".
    func testTheSelfViewsRegionSurvivesTheShortestSupportedScreen() {
        // iPhone SE, portrait, minus generous system chrome: the smallest
        // vertical space this screen is ever laid out in.
        let shortestUsableHeight: CGFloat = 667 - 100

        let vertical = shortestUsableHeight
            - Size.callHeaderBand
            - Size.callControlsBand
        XCTAssertGreaterThan(
            vertical, Size.localVideoHeight,
            "The self-view must have room to move between the countdown and the controls"
        )

        // iPhone SE width, same idea horizontally.
        let horizontal: CGFloat = 375 - (Space.sm * 2)
        XCTAssertGreaterThan(
            horizontal, Size.localVideoWidth,
            "The self-view must have room to move between the screen edges"
        )
    }
}
