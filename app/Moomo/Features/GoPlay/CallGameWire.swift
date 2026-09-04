import Foundation

/// The in-call data channel, and the lobby protocol that runs on it.
///
/// One LiveKit topic carries everything an in-call experience needs to say —
/// `baybe.callgames.v1`. It is deliberately generic: the channel outlived the
/// first game built on it, and it will outlive the next. Features are told
/// apart by the `channel` field inside each message rather than by a topic
/// each, so a build that has never heard of a channel drops its traffic
/// cleanly instead of half-decoding it.
///
/// Design rules, all load-bearing:
///  - Every message carries `version`, `channel`, `sequence`, `senderID` and
///    `sentAtMillis`. Version lets a newer build refuse to half-understand an
///    older one; sequence kills duplicates; sender id is checked against the
///    packet's own participant identity and never trusted from the body.
///  - Lifecycle messages go **reliable** — losing one strands the other
///    person on the wrong screen, or in the wrong story about what just
///    happened.
///  - Nothing on this channel is ever rendered as user-authored text. Chat
///    lives in Firestore, where rules and moderation apply; this channel
///    carries choices from fixed decks and lifecycle flags, so it cannot
///    become an unmoderated messaging side channel.
enum CallGameWire {
    /// The LiveKit data topic. Packets on any other topic are not ours.
    static let topic = "baybe.callgames.v1"

    /// Bumped when a change would make an older build misread a message.
    /// Mismatched versions are dropped rather than guessed at.
    static let version = 1
}

/// Which feature a packet belongs to. Required on the wire, so a lobby
/// message can never be mistaken for an icebreaker one (or the reverse) just
/// because their optional fields happen to line up.
enum CallGameChannel: String, Codable, Sendable {
    /// Choosing a game together: invite, accept, decline, leave.
    case lobby
    /// The dating icebreakers — see `DateIcebreakerWire`.
    case icebreakers
}

// MARK: - Lobby messages

enum CallGameMessageKind: String, Codable, Sendable {
    /// "Shall we play this?" — sent by whoever picked from the list.
    case invite
    /// "Yes." Both sides then open the game.
    case accept
    /// "Not that one." The picker stays open on the inviter's side.
    case decline
    /// "I'm going back to the call." Never ends the call itself.
    case exit
}

/// One lobby message. Flat rather than an enum-with-payloads so the JSON
/// stays trivially forward-compatible: an older build decoding a newer
/// message it doesn't understand sees `nil` fields, not a decode failure.
struct CallGameMessage: Sendable, Codable, Equatable {
    var version: Int
    var channel: CallGameChannel
    /// The one shared game this message is about. A packet from the round
    /// before is not a packet about this one.
    var sessionID: String
    var sequence: Int
    var senderID: String
    var sentAtMillis: Double
    var kind: CallGameMessageKind
    /// Which game is being proposed. Absent on `exit`.
    var game: CallGame?
    /// invite / accept: who is on the other end.
    var seat: CallGameSeat?

    init(
        sessionID: String,
        sequence: Int,
        senderID: String,
        kind: CallGameMessageKind,
        game: CallGame? = nil,
        seat: CallGameSeat? = nil,
        sentAt: Date = Date()
    ) {
        self.version = CallGameWire.version
        self.channel = .lobby
        self.sessionID = sessionID
        self.sequence = sequence
        self.senderID = senderID
        self.sentAtMillis = sentAt.timeIntervalSince1970 * 1000
        self.kind = kind
        self.game = game
        self.seat = seat
    }

    var sentAt: Date { Date(timeIntervalSince1970: sentAtMillis / 1000) }

    /// Every lobby message is a lifecycle message. There is nothing here that
    /// is superseded a moment later, so nothing here may be dropped.
    var needsReliableDelivery: Bool { true }
}

// MARK: - Codec

/// JSON on the wire.
///
/// Chosen over a binary format on purpose: the traffic is a handful of small
/// packets per call, so the size difference is irrelevant next to the audio
/// and video already flowing, and a human-readable packet is worth a great
/// deal when debugging something that only misbehaves across two physical
/// devices.
enum CallGameCodec {
    static func encode(_ message: CallGameMessage) throws -> Data {
        try JSONEncoder().encode(message)
    }

    /// Decodes a lobby packet, or nil if it isn't one this build understands.
    /// Never throws at the call site: a malformed packet on a live call is
    /// something to drop quietly, not something to crash on.
    static func decode(_ data: Data) -> CallGameMessage? {
        guard let message = try? JSONDecoder().decode(CallGameMessage.self, from: data) else {
            return nil
        }
        guard message.version == CallGameWire.version else { return nil }
        guard message.channel == .lobby else { return nil }
        return message
    }
}
