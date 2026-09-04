import CryptoKit
import Foundation

/// The icebreaker protocol, carried on the shared in-call data channel
/// (`CallGameWire.topic`) under its own channel tag.
///
/// **Commit then reveal.** The whole feature turns on both people answering
/// honestly at the same time, and there is no server in the loop to hold two
/// answers and release them together — the packets go device to device. So
/// each phone sends a *commitment* first: the SHA-256 digest of its answer
/// plus a random salt, which says "I have decided" while saying nothing about
/// what was decided. Only once the other side's commitment has arrived does a
/// phone send the answer itself, along with the salt, and the receiver checks
/// the digest it was promised earlier against what actually turned up.
///
/// The consequence is the guarantee worth having: an answer's plaintext never
/// leaves a device until the other device has already locked its own answer
/// in, so neither person's phone is ever in a position to show them what the
/// other said before they have committed. A tampered client can send garbage
/// or nothing, but it cannot peek — and a reveal that doesn't match its
/// commitment is dropped rather than displayed.
enum DateIcebreakerWire {
    /// Bumped when a change would make an older build misread a message.
    static let version = 1

    /// Icebreakers share the generic call-games topic. The `channel` field
    /// inside the message is what tells them apart from the lobby's traffic.
    static var topic: String { CallGameWire.topic }
}

// MARK: - Messages

enum DateIcebreakerMessageKind: String, Codable, Sendable {
    /// "I've answered." Carries the digest, and nothing that could be read
    /// back into an answer.
    case commit
    /// "Here's what I said." Carries the answer and the salt, so the earlier
    /// commitment can be checked against it.
    case reveal
    /// "I've closed the cards." The other side stops offering prompts rather
    /// than being left answering alone.
    case exit
}

/// One icebreaker message. Flat, so an older build decoding a newer message
/// sees `nil` fields rather than a decode failure.
struct DateIcebreakerMessage: Sendable, Codable, Equatable {
    var version: Int
    var channel: CallGameChannel
    /// Which round this is about. Round ids are derived identically on both
    /// devices from the call session, so they need no negotiating.
    var roundID: String
    var sequence: Int
    var senderID: String
    var sentAtMillis: Double
    var kind: DateIcebreakerMessageKind
    /// commit: the promise.
    var digest: String?
    /// reveal: the answer…
    var submission: IcebreakerSubmission?
    /// …and the salt that makes the digest check out.
    var salt: String?

    init(
        roundID: String,
        sequence: Int,
        senderID: String,
        kind: DateIcebreakerMessageKind,
        digest: String? = nil,
        submission: IcebreakerSubmission? = nil,
        salt: String? = nil,
        sentAt: Date = Date()
    ) {
        self.version = DateIcebreakerWire.version
        self.channel = .icebreakers
        self.roundID = roundID
        self.sequence = sequence
        self.senderID = senderID
        self.sentAtMillis = sentAt.timeIntervalSince1970 * 1000
        self.kind = kind
        self.digest = digest
        self.submission = submission
        self.salt = salt
    }

    var sentAt: Date { Date(timeIntervalSince1970: sentAtMillis / 1000) }

    /// Every message here is a lifecycle message: losing a commitment strands
    /// the other person on a card that will never flip.
    var needsReliableDelivery: Bool { true }
}

// MARK: - Commitments

/// The commit half of commit/reveal.
enum IcebreakerCommitment {
    /// A fresh salt. Without one, a three-option answer would be trivially
    /// brute-forced from its digest — there are only so many answers, and
    /// hashing all of them takes no time at all.
    static func makeSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The promise: SHA-256 over the round, the answer, and the salt.
    ///
    /// The round id is inside the digest on purpose — otherwise a commitment
    /// made for round one could be replayed as a commitment for round three.
    static func digest(round roundID: String, submission: IcebreakerSubmission, salt: String) -> String {
        let material = "\(roundID)|\(submission.canonicalForm)|\(salt)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Whether a revealed answer is the one that was promised. A reveal that
    /// fails this is a client that changed its mind after seeing something it
    /// shouldn't have — dropped, and never shown.
    static func verify(
        digest promised: String,
        round roundID: String,
        submission: IcebreakerSubmission,
        salt: String
    ) -> Bool {
        digest(round: roundID, submission: submission, salt: salt) == promised
    }
}

// MARK: - Codec

enum DateIcebreakerCodec {
    static func encode(_ message: DateIcebreakerMessage) throws -> Data {
        try JSONEncoder().encode(message)
    }

    /// Decodes an icebreaker packet, or nil if it isn't one this build
    /// understands. Anything on the lobby channel, at another version, or
    /// simply malformed is dropped without complaint — a live call is no
    /// place to throw.
    static func decode(_ data: Data) -> DateIcebreakerMessage? {
        guard let message = try? JSONDecoder().decode(DateIcebreakerMessage.self, from: data) else {
            return nil
        }
        guard message.version == DateIcebreakerWire.version else { return nil }
        guard message.channel == .icebreakers else { return nil }
        return message
    }
}
