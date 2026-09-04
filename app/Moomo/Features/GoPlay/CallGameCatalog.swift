import Foundation

/// The games Go Play can put in front of two people who are already on a
/// call, and the vocabulary every one of them shares.
///
/// Go Play is a *mode*, not a game: two people match on video first, then
/// choose something to do together. This catalogue is the list they choose
/// from, and it is deliberately the only place that knows which entries are
/// real. A game that has not been built yet still appears — greyed, honest,
/// and unselectable — because a picker that hides its roadmap tells a user
/// nothing, while a picker that lies about it wastes a call.
enum CallGame: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Three quick dating prompts, played over the same commit/reveal
    /// machinery Video Match uses on its own. The one entry that is finished.
    case icebreakers
    case snakeClash
    case ludo
    case chase
    case cards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icebreakers: "Icebreakers"
        case .snakeClash: "Snake Clash"
        case .ludo: "Ludo"
        case .chase: "Chase"
        case .cards: "Cards"
        }
    }

    var tagline: String {
        switch self {
        case .icebreakers: "Three quick questions, answered at the same time"
        case .snakeClash: "Race for space without crossing lines"
        case .ludo: "Four tokens home, one roll at a time"
        case .chase: "One of you runs, the other counts down"
        // No stakes anywhere in the copy, and none in the game: Cards is
        // played for the conversation. There is no wager, no balance, no
        // purchase, and nothing that can be exchanged for anything.
        case .cards: "Friendly hands — just for fun, never for money"
        }
    }

    var symbol: String {
        switch self {
        case .icebreakers: "bubble.left.and.bubble.right.fill"
        case .snakeClash: "scribble.variable"
        case .ludo: "die.face.4.fill"
        case .chase: "figure.run"
        case .cards: "suit.spade.fill"
        }
    }

    /// Whether choosing this actually starts something. Everything else is a
    /// "Coming soon" row: visible, tappable-looking to nobody, and refused by
    /// the session if a message ever proposes it.
    var isPlayable: Bool {
        switch self {
        case .icebreakers: true
        case .snakeClash, .ludo, .chase, .cards: false
        }
    }

    /// The order the picker lists them in: what can be played now, first.
    static var pickerOrder: [CallGame] {
        allCases.sorted { lhs, rhs in
            lhs.isPlayable == rhs.isPlayable
                ? allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
                : lhs.isPlayable
        }
    }
}

/// One person at the table, as any in-call game sees them.
///
/// The `id` is the media room's participant identity — the signed-in uid —
/// because that is the string both devices can compare without agreeing on
/// anything first.
struct CallGameSeat: Equatable, Codable, Sendable {
    var id: String
    var displayName: String
    var photoPath: String?

    init(id: String, displayName: String, photoPath: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.photoPath = photoPath
    }
}
