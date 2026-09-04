import XCTest
@testable import Moomo

/// The icebreaker wire: what survives a round trip, what is dropped on
/// sight, and the commitment arithmetic the whole privacy guarantee rests on.
final class DateIcebreakerWireTests: XCTestCase {

    private let round = "session-1#0"

    private func message(
        kind: DateIcebreakerMessageKind = .commit,
        digest: String? = "abc",
        submission: IcebreakerSubmission? = nil,
        salt: String? = nil
    ) -> DateIcebreakerMessage {
        DateIcebreakerMessage(
            roundID: round,
            sequence: 1,
            senderID: "alice",
            kind: kind,
            digest: digest,
            submission: submission,
            salt: salt
        )
    }

    // MARK: - Round trip

    func testAMessageSurvivesTheRoundTripIntact() throws {
        let sent = message(
            kind: .reveal,
            digest: nil,
            submission: IcebreakerSubmission(choice: 1, guess: 2),
            salt: "cafe"
        )

        let decoded = DateIcebreakerCodec.decode(try DateIcebreakerCodec.encode(sent))

        XCTAssertEqual(decoded, sent, "Everything the receiver acts on must survive encoding")
        XCTAssertEqual(decoded?.submission?.choice, 1)
        XCTAssertEqual(decoded?.submission?.guess, 2)
    }

    func testEveryMessageIsSentReliably() {
        for kind in [DateIcebreakerMessageKind.commit, .reveal, .exit] {
            XCTAssertTrue(
                message(kind: kind).needsReliableDelivery,
                "\(kind) strands the other person on a card that never flips if it is dropped"
            )
        }
    }

    // MARK: - Dropping

    func testAMessageFromAnotherVersionIsDropped() throws {
        var wrong = message()
        wrong.version = DateIcebreakerWire.version + 1

        XCTAssertNil(
            DateIcebreakerCodec.decode(try JSONEncoder().encode(wrong)),
            "A version this build cannot fully understand is dropped, never half-read"
        )
    }

    /// The two features share one LiveKit topic, so the channel tag is the
    /// only thing keeping their traffic apart. Each decoder must refuse the
    /// other's messages outright.
    func testTheTwoChannelsRefuseEachOthersTraffic() throws {
        let lobby = CallGameMessage(
            sessionID: "g1", sequence: 1, senderID: "alice", kind: .invite, game: .icebreakers
        )
        let icebreaker = message()

        XCTAssertNil(
            DateIcebreakerCodec.decode(try CallGameCodec.encode(lobby)),
            "A lobby message must never decode as an icebreaker one"
        )
        XCTAssertNil(
            CallGameCodec.decode(try DateIcebreakerCodec.encode(icebreaker)),
            "An icebreaker message must never decode as a lobby one"
        )
    }

    func testMalformedBytesAreDroppedRatherThanThrown() {
        XCTAssertNil(DateIcebreakerCodec.decode(Data("not json".utf8)))
        XCTAssertNil(DateIcebreakerCodec.decode(Data()))
        XCTAssertNil(DateIcebreakerCodec.decode(Data("{\"version\":1}".utf8)))
    }

    // MARK: - Commitments

    func testACommitmentIsStableForTheSameAnswerAndSalt() {
        let submission = IcebreakerSubmission(choice: 1)
        let salt = "0011"

        XCTAssertEqual(
            IcebreakerCommitment.digest(round: round, submission: submission, salt: salt),
            IcebreakerCommitment.digest(round: round, submission: submission, salt: salt),
            "Both devices must compute the same digest from the same inputs"
        )
    }

    func testADifferentAnswerOrSaltChangesTheCommitment() {
        let base = IcebreakerCommitment.digest(
            round: round, submission: IcebreakerSubmission(choice: 0), salt: "aa"
        )

        XCTAssertNotEqual(
            base,
            IcebreakerCommitment.digest(
                round: round, submission: IcebreakerSubmission(choice: 1), salt: "aa"
            ),
            "A different answer must not satisfy an existing commitment"
        )
        XCTAssertNotEqual(
            base,
            IcebreakerCommitment.digest(
                round: round, submission: IcebreakerSubmission(choice: 0), salt: "bb"
            ),
            "The salt is what stops a three-option answer being brute-forced"
        )
    }

    /// A commitment made for one round must not be replayable as a
    /// commitment for another.
    func testACommitmentIsBoundToItsRound() {
        let submission = IcebreakerSubmission(choice: 2)

        XCTAssertNotEqual(
            IcebreakerCommitment.digest(round: "s#0", submission: submission, salt: "aa"),
            IcebreakerCommitment.digest(round: "s#1", submission: submission, salt: "aa")
        )
    }

    func testTheGuessIsPartOfWhatIsCommittedTo() {
        XCTAssertNotEqual(
            IcebreakerCommitment.digest(
                round: round, submission: IcebreakerSubmission(choice: 0, guess: 1), salt: "aa"
            ),
            IcebreakerCommitment.digest(
                round: round, submission: IcebreakerSubmission(choice: 0, guess: 2), salt: "aa"
            ),
            "A client must not be able to change its guess after seeing their answer"
        )
    }

    func testVerificationAcceptsThePromiseAndRefusesEverythingElse() {
        let submission = IcebreakerSubmission(choice: 1, guess: 0)
        let salt = IcebreakerCommitment.makeSalt()
        let promised = IcebreakerCommitment.digest(round: round, submission: submission, salt: salt)

        XCTAssertTrue(IcebreakerCommitment.verify(
            digest: promised, round: round, submission: submission, salt: salt
        ))
        XCTAssertFalse(
            IcebreakerCommitment.verify(
                digest: promised,
                round: round,
                submission: IcebreakerSubmission(choice: 0, guess: 0),
                salt: salt
            ),
            "Revealing something other than what was promised must not verify"
        )
    }

    func testSaltsAreNotReused() {
        let salts = Set((0..<50).map { _ in IcebreakerCommitment.makeSalt() })
        XCTAssertEqual(salts.count, 50, "A repeated salt would leak an answer by comparison")
    }

    // MARK: - The deck

    /// Both devices derive the deck from the shared session id, so the rule
    /// has to be stable across processes — which is exactly what Swift's own
    /// `hashValue` is not.
    func testTheDeckIsDeterministicFromTheSessionID() {
        let first = IcebreakerDeck.prompts(forSessionID: "session-abc")
        let second = IcebreakerDeck.prompts(forSessionID: "session-abc")

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        // Pinned to the published FNV-1a 64 vectors: a "cleanup" that
        // swapped in Swift's own hashing would still pass every same-process
        // assertion above and quietly give two phones different prompts.
        XCTAssertEqual(IcebreakerDeck.fnv1a("abc"), 0xe71f_a219_0541_574b)
        XCTAssertEqual(IcebreakerDeck.fnv1a("session-abc"), 0xe909_c864_ab05_9bea)
        XCTAssertNotEqual(
            first.map(\.id),
            IcebreakerDeck.prompts(forSessionID: "session-xyz").map(\.id),
            "Different calls should not all get the same three prompts"
        )
    }

    func testEveryCallGetsOneOfEachKindInOrder() {
        for session in ["a", "b", "session-1", "9f2c", "zzzz"] {
            XCTAssertEqual(
                IcebreakerDeck.prompts(forSessionID: session).map(\.kind),
                [.thisOrThat, .flag, .guessMyAnswer],
                "The run is This or That, then a flag, then Guess My Answer"
            )
        }
    }

    func testEveryPromptOffersAtLeastTwoAnswers() {
        let deck = IcebreakerDeck.thisOrThat + IcebreakerDeck.flags + IcebreakerDeck.guessMyAnswer
        for prompt in deck {
            XCTAssertGreaterThanOrEqual(prompt.options.count, 2, "\(prompt.id) needs a choice")
            XCTAssertFalse(prompt.discussion.isEmpty, "\(prompt.id) needs somewhere to go next")
        }
        XCTAssertEqual(
            Set(deck.map(\.id)).count, deck.count, "Prompt ids must be unique across the decks"
        )
    }
}
