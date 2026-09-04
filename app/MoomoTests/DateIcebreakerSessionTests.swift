import XCTest
@testable import Moomo

/// The icebreakers as two devices actually experience them.
///
/// Both sides are real `DateIcebreakerSessionModel`s wired to a
/// `LoopbackDataTransport` pair, so these are genuine two-device
/// conversations — commit, reveal, verify — with no room and no network. The
/// schedule is driven by hand rather than by a clock, so nothing here races.
@MainActor
final class DateIcebreakerSessionTests: XCTestCase {

    private let aliceID = "a-alice"
    private let bobID = "z-bob"
    private let sessionID = "session-abc"

    /// Round cues far enough apart that a test can sit between two of them.
    private let schedule = IcebreakerSchedule(cues: [10, 20, 30], summaryAt: 40, summaryDuration: 20)

    private func makePair() -> (
        alice: DateIcebreakerSessionModel,
        bob: DateIcebreakerSessionModel,
        aliceTransport: LoopbackDataTransport,
        bobTransport: LoopbackDataTransport
    ) {
        let (first, second) = LoopbackDataTransport.pair(aliceID, bobID)
        let alice = DateIcebreakerSessionModel(
            transport: first,
            sessionID: sessionID,
            localSeat: CallGameSeat(id: aliceID, displayName: "Alice"),
            peerSeat: CallGameSeat(id: bobID, displayName: "Bob"),
            schedule: schedule,
            feedback: SilentIcebreakerFeedback()
        )
        let bob = DateIcebreakerSessionModel(
            transport: second,
            sessionID: sessionID,
            localSeat: CallGameSeat(id: bobID, displayName: "Bob"),
            peerSeat: CallGameSeat(id: aliceID, displayName: "Alice"),
            schedule: schedule,
            feedback: SilentIcebreakerFeedback()
        )
        alice.begin()
        bob.begin()
        alice.scheduleFromCallStart()
        bob.scheduleFromCallStart()
        return (alice, bob, first, second)
    }

    private func settle(_ ms: UInt64 = 30) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// Lets both sides finish everything the last action started: the commit
    /// goes out, the peer reacts, the reveal goes out, the peer verifies.
    private func exchange(
        _ first: DateIcebreakerSessionModel,
        _ second: DateIcebreakerSessionModel
    ) async {
        for _ in 0..<5 {
            await first.drainPendingSends()
            await second.drainPendingSends()
            await settle(15)
        }
    }

    /// Every icebreaker message this transport has been asked to send.
    private func sentMessages(_ transport: LoopbackDataTransport) -> [DateIcebreakerMessage] {
        transport.sent.compactMap { DateIcebreakerCodec.decode($0.payload) }
    }

    private func openFirstRound() async -> (
        alice: DateIcebreakerSessionModel,
        bob: DateIcebreakerSessionModel,
        aliceTransport: LoopbackDataTransport,
        bobTransport: LoopbackDataTransport
    ) {
        let pair = makePair()
        pair.alice.advance(to: 10)
        pair.bob.advance(to: 10)
        await settle()
        return pair
    }

    // MARK: - The schedule

    func testNothingAppearsBeforeItsCue() async {
        let (alice, _, _, _) = makePair()

        alice.advance(to: 9)

        XCTAssertEqual(alice.stage, .idle, "A prompt must not arrive before its cue")
    }

    func testTheFirstPromptArrivesOnItsCue() async {
        let (alice, _, _, _) = makePair()

        alice.advance(to: 10)

        guard case .round(let round) = alice.stage else {
            return XCTFail("Expected the first round, got \(alice.stage)")
        }
        XCTAssertEqual(round.index, 0)
        XCTAssertEqual(round.prompt.kind, .thisOrThat, "The run opens with This or That")
        XCTAssertEqual(round.phase, .answering)
    }

    /// The cue is fed once a second from the call's own clock, so arriving at
    /// the same value twice must not restart anything.
    func testRepeatedTicksDoNotReopenARound() async {
        let (alice, bob, _, _) = await openFirstRound()
        alice.choose(0)
        bob.choose(0)
        await exchange(alice, bob)

        alice.advance(to: 10)
        alice.advance(to: 11)

        XCTAssertEqual(alice.currentRound?.phase, .revealed, "A tick must not undo an answered round")
    }

    func testTheClockMovesOnAndMarksAnUnansweredRoundAsSuch() async {
        let (alice, _, _, _) = await openFirstRound()

        alice.advance(to: 20)

        guard case .round(let round) = alice.stage else {
            return XCTFail("Expected the second round, got \(alice.stage)")
        }
        XCTAssertEqual(round.index, 1, "The clock opens the next prompt on its own")
        XCTAssertEqual(round.prompt.kind, .flag)
        XCTAssertEqual(
            alice.rounds[0].phase, .unanswered,
            "A round nobody finished is recorded as unanswered, not as a wrong answer"
        )
    }

    func testAClockThatGoesBackwardsDoesNotReopenAnsweredRounds() async {
        let (alice, bob, _, _) = await openFirstRound()
        alice.choose(0)
        bob.choose(0)
        await exchange(alice, bob)
        alice.advance(to: 20)

        alice.advance(to: 10)

        XCTAssertEqual(alice.currentRound?.index, 1, "Time only runs one way here")
        XCTAssertEqual(alice.rounds[0].phase, .revealed, "…and an answered round stays answered")
    }

    // MARK: - Privacy

    /// The guarantee the whole design exists for: an answer's plaintext must
    /// not leave the phone until the other phone has already locked its own
    /// answer in behind a digest.
    func testAnAnswerDoesNotLeaveTheDeviceBeforeTheOtherHasCommitted() async {
        let (alice, bob, aliceTransport, _) = await openFirstRound()

        alice.choose(0)
        await exchange(alice, bob)

        let sent = sentMessages(aliceTransport)
        XCTAssertTrue(sent.contains { $0.kind == .commit }, "The commitment goes out immediately")
        XCTAssertFalse(
            sent.contains { $0.kind == .reveal },
            "The answer itself must stay on the phone until they have committed too"
        )
        XCTAssertNil(
            sent.first(where: { $0.kind == .commit })?.submission,
            "A commitment must carry nothing that can be read back into an answer"
        )
    }

    /// And the receiving half of the same guarantee: even if a tampered
    /// client reveals early, this side must not look at the answer until it
    /// has committed its own.
    func testAnEarlyRevealIsNotShownUntilThisSideHasAnswered() async throws {
        let (alice, _, _, bobTransport) = await openFirstRound()
        let roundID = try XCTUnwrap(alice.currentRound?.id)
        let bobsAnswer = IcebreakerSubmission(choice: 1)
        let salt = IcebreakerCommitment.makeSalt()

        // Bob's client jumps the gun: commit and reveal, both before Alice
        // has touched anything.
        bobTransport.deliverToPeerForTesting(try DateIcebreakerCodec.encode(.init(
            roundID: roundID, sequence: 1, senderID: bobID, kind: .commit,
            digest: IcebreakerCommitment.digest(round: roundID, submission: bobsAnswer, salt: salt)
        )))
        bobTransport.deliverToPeerForTesting(try DateIcebreakerCodec.encode(.init(
            roundID: roundID, sequence: 2, senderID: bobID, kind: .reveal,
            submission: bobsAnswer, salt: salt
        )))
        await settle()

        XCTAssertNil(alice.currentRound?.peer, "Their answer must not be readable yet")
        XCTAssertEqual(alice.currentRound?.phase, .answering, "…and the card must still be open")

        // Once Alice answers, it may be shown — and is.
        alice.choose(0)
        await alice.drainPendingSends()
        await settle()

        XCTAssertEqual(alice.currentRound?.peer, bobsAnswer)
        XCTAssertEqual(alice.currentRound?.phase, .revealed)
    }

    /// A client that reveals something other than what it promised is a
    /// client that changed its mind after seeing an answer. Refused.
    func testARevealThatDoesNotMatchItsCommitmentIsRefused() async throws {
        let (alice, _, _, bobTransport) = await openFirstRound()
        let roundID = try XCTUnwrap(alice.currentRound?.id)
        let salt = IcebreakerCommitment.makeSalt()
        let promised = IcebreakerCommitment.digest(
            round: roundID, submission: IcebreakerSubmission(choice: 0), salt: salt
        )

        alice.choose(1)
        await alice.drainPendingSends()

        bobTransport.deliverToPeerForTesting(try DateIcebreakerCodec.encode(.init(
            roundID: roundID, sequence: 1, senderID: bobID, kind: .commit, digest: promised
        )))
        await settle()
        // Promised nought, revealed one.
        bobTransport.deliverToPeerForTesting(try DateIcebreakerCodec.encode(.init(
            roundID: roundID, sequence: 2, senderID: bobID, kind: .reveal,
            submission: IcebreakerSubmission(choice: 1), salt: salt
        )))
        await settle()

        XCTAssertNil(alice.currentRound?.peer, "An unverifiable answer is never shown")
        XCTAssertEqual(alice.currentRound?.phase, .waitingForPeer)
        XCTAssertNotNil(alice.notice, "…and the user is told why the card didn't flip")
    }

    func testAPacketClaimingToBeFromSomeoneElseIsDropped() async throws {
        let (alice, _, _, bobTransport) = await openFirstRound()
        let roundID = try XCTUnwrap(alice.currentRound?.id)

        // The body says Alice; the transport says Bob. The transport wins.
        bobTransport.deliverToPeerForTesting(try DateIcebreakerCodec.encode(.init(
            roundID: roundID, sequence: 1, senderID: aliceID, kind: .commit, digest: "whatever"
        )))
        alice.choose(0)
        await alice.drainPendingSends()
        await settle()

        XCTAssertEqual(
            alice.currentRound?.phase, .waitingForPeer,
            "A forged sender must not count as the other person committing"
        )
    }

    // MARK: - Answering

    func testBothAnswersFlipTheCardOnBothDevices() async {
        let (alice, bob, _, _) = await openFirstRound()

        alice.choose(0)
        bob.choose(0)
        await exchange(alice, bob)

        XCTAssertEqual(alice.currentRound?.phase, .revealed)
        XCTAssertEqual(bob.currentRound?.phase, .revealed)
        XCTAssertEqual(alice.currentRound?.peer?.choice, 0)
        XCTAssertEqual(bob.currentRound?.peer?.choice, 0)
        XCTAssertEqual(alice.currentRound?.outcome?.isAgreement, true)
        XCTAssertEqual(bob.currentRound?.outcome?.isAgreement, true)
    }

    func testDifferentAnswersRevealBothOfThem() async {
        let (alice, bob, _, _) = await openFirstRound()

        alice.choose(0)
        bob.choose(1)
        await exchange(alice, bob)

        XCTAssertEqual(alice.currentRound?.outcome?.isAgreement, false)
        XCTAssertEqual(alice.currentRound?.peer?.choice, 1)
        XCTAssertEqual(bob.currentRound?.peer?.choice, 0)
        let headline = alice.currentRound?.outcome?.headline ?? ""
        XCTAssertTrue(headline.contains("Bob"), "A difference names who said what: \(headline)")
    }

    /// Both people tapping at the same moment is the ordinary case, not an
    /// edge one — and it must reveal exactly once on each side.
    func testSimultaneousAnswersRevealExactlyOnce() async {
        let (alice, bob, aliceTransport, bobTransport) = await openFirstRound()

        alice.choose(1)
        bob.choose(0)
        await exchange(alice, bob)

        XCTAssertEqual(alice.currentRound?.phase, .revealed)
        XCTAssertEqual(bob.currentRound?.phase, .revealed)
        XCTAssertEqual(
            sentMessages(aliceTransport).filter { $0.kind == .reveal }.count, 1,
            "An answer is revealed once, not once per inbound packet"
        )
        XCTAssertEqual(sentMessages(bobTransport).filter { $0.kind == .reveal }.count, 1)
    }

    /// Reliable delivery is not exactly-once delivery: a repeated commit
    /// must not make this side send its answer a second time.
    func testADuplicatedCommitDoesNotProduceASecondReveal() async throws {
        let (alice, bob, aliceTransport, bobTransport) = await openFirstRound()
        let roundID = try XCTUnwrap(alice.currentRound?.id)
        alice.choose(0)
        bob.choose(0)
        await exchange(alice, bob)

        bobTransport.deliverToPeerForTesting(try DateIcebreakerCodec.encode(.init(
            roundID: roundID, sequence: 99, senderID: bobID, kind: .commit, digest: "second-promise"
        )))
        await exchange(alice, bob)

        XCTAssertEqual(
            sentMessages(aliceTransport).filter { $0.kind == .reveal }.count, 1,
            "One answer, revealed once, whatever arrives afterwards"
        )
        XCTAssertEqual(alice.currentRound?.phase, .revealed)
    }

    func testTappingAgainAfterAnsweringChangesNothing() async {
        let (alice, _, aliceTransport, _) = await openFirstRound()

        alice.choose(0)
        await alice.drainPendingSends()
        alice.choose(1)
        await alice.drainPendingSends()
        await settle()

        XCTAssertEqual(alice.currentRound?.local?.choice, 0, "An answer is final once it is committed")
        XCTAssertEqual(sentMessages(aliceTransport).filter { $0.kind == .commit }.count, 1)
    }

    // MARK: - Guess My Answer

    func testGuessMyAnswerAsksTwiceAndCommitsOnlyOnTheSecond() async {
        let (alice, _, aliceTransport, _) = makePair()
        alice.advance(to: 30)

        guard case .round(let opening) = alice.stage else {
            return XCTFail("Expected the third round, got \(alice.stage)")
        }
        XCTAssertEqual(opening.prompt.kind, .guessMyAnswer)
        XCTAssertEqual(opening.phase, .guessingPeer, "Phase one is guessing what they will say")

        // Phase one: nothing may be committed yet — the answer being
        // committed to has not been given.
        alice.choose(2)
        await alice.drainPendingSends()
        XCTAssertEqual(alice.currentRound?.phase, .answering, "Phase two is your own answer")
        XCTAssertEqual(alice.currentRound?.stagedGuess, 2)
        XCTAssertTrue(
            sentMessages(aliceTransport).isEmpty,
            "A guess alone must not be committed — the answer is still to come"
        )

        alice.choose(0)
        await alice.drainPendingSends()
        XCTAssertEqual(alice.currentRound?.local, IcebreakerSubmission(choice: 0, guess: 2))
        XCTAssertEqual(sentMessages(aliceTransport).filter { $0.kind == .commit }.count, 1)
    }

    func testGuessMyAnswerScoresEachGuessAgainstTheOtherPersonsAnswer() async {
        let (alice, bob, _, _) = makePair()
        alice.advance(to: 30)
        bob.advance(to: 30)
        await settle()

        // Alice guesses Bob will say 1 (he does); Bob guesses Alice will say
        // 2 (she says 0).
        alice.choose(1); alice.choose(0)
        bob.choose(2); bob.choose(1)
        await exchange(alice, bob)

        XCTAssertEqual(alice.currentRound?.outcome?.localGuessedRight, true)
        XCTAssertEqual(alice.currentRound?.outcome?.peerGuessedRight, false)
        XCTAssertEqual(bob.currentRound?.outcome?.localGuessedRight, false)
        XCTAssertEqual(bob.currentRound?.outcome?.peerGuessedRight, true)
    }

    // MARK: - The reveal beat

    func testTheRevealSetsTheAnimationStateAndThenClearsIt() async {
        let (alice, bob, _, _) = await openFirstRound()

        alice.choose(0)
        bob.choose(0)
        await exchange(alice, bob)

        XCTAssertTrue(alice.isRevealing, "The card must play its flip rather than swapping text")

        alice.endRevealAnimation()
        XCTAssertFalse(alice.isRevealing)
    }

    func testARevealArrivingAfterTheClockMovedOnDoesNotAnimateOverTheNextPrompt() async {
        let (alice, bob, _, _) = await openFirstRound()
        alice.choose(0)
        await alice.drainPendingSends()

        // The clock moves on before Bob answers…
        alice.advance(to: 20)
        alice.endRevealAnimation()
        // …and only then does his answer land.
        bob.choose(0)
        await exchange(alice, bob)

        XCTAssertEqual(alice.currentRound?.index, 1, "The next prompt keeps the screen")
        XCTAssertFalse(alice.isRevealing, "A stale reveal must not animate over the live card")
    }

    // MARK: - Summary

    func testTheSummaryReportsOnlyWhatWasActuallyAnswered() async {
        let (alice, bob, _, _) = makePair()

        alice.advance(to: 10); bob.advance(to: 10); await settle()
        alice.choose(0); bob.choose(0)
        await exchange(alice, bob)

        alice.advance(to: 20); bob.advance(to: 20); await settle()
        alice.choose(0); bob.choose(1)
        await exchange(alice, bob)

        // Nobody answers the third.
        alice.advance(to: 30); bob.advance(to: 30); await settle()
        alice.advance(to: 40)

        guard case .summary(let summary) = alice.stage else {
            return XCTFail("Expected the summary, got \(alice.stage)")
        }
        XCTAssertEqual(summary.answeredRounds, 2, "An unanswered round is left out, not reported")
        XCTAssertEqual(summary.lines.count, 2)
        XCTAssertEqual(summary.agreements, 1)
        XCTAssertEqual(alice.rounds[2].phase, .unanswered)
    }

    func testARunNobodyAnsweredClosesRatherThanShowingAnEmptySummary() async {
        let (alice, _, _, _) = makePair()

        alice.advance(to: 40)

        XCTAssertEqual(
            alice.stage, .closed,
            "A 'you discovered…' card that discovered nothing is worse than nothing"
        )
    }

    // MARK: - Leaving

    func testClosingTheCardsTellsTheOtherSide() async {
        let (alice, bob, _, _) = await openFirstRound()

        alice.dismiss()
        await exchange(alice, bob)

        XCTAssertEqual(alice.stage, .closed)
        XCTAssertEqual(bob.stage, .closed, "A card only one person can see is a card nobody answers")
        XCTAssertNotNil(bob.notice)
    }

    /// Go Play's pair asked for this off a list, so it starts now rather
    /// than a schedule's-worth of seconds later.
    func testAnOnDemandRunOpensItsFirstPromptImmediately() async {
        let (alice, _, _, _) = makePair()

        alice.startOnDemand(atElapsed: 72)

        XCTAssertEqual(alice.currentRound?.index, 0, "Choosing it is asking for it now")
        // …and the rest of the run keeps the schedule's spacing.
        alice.advance(to: 82)
        XCTAssertEqual(alice.currentRound?.index, 1)
    }

    /// Go Play can reach the icebreakers twice in one call — leave the game,
    /// pick it again. It must resume, not replay.
    func testASecondOnDemandRunResumesWhereTheFirstStopped() async {
        let (alice, bob, _, _) = makePair()
        alice.startOnDemand(atElapsed: 40)
        bob.startOnDemand(atElapsed: 40)
        await settle()
        alice.choose(0)
        bob.choose(0)
        await exchange(alice, bob)
        XCTAssertEqual(alice.currentRound?.index, 0)

        alice.dismiss()
        alice.startOnDemand(atElapsed: 90)

        XCTAssertEqual(
            alice.currentRound?.index, 1,
            "Picking it again must not re-ask a question they already answered"
        )
        XCTAssertEqual(alice.rounds[0].phase, .revealed, "…and the first answer still stands")
    }

    func testPickingItAgainWithNothingLeftToAskShowsTheSummary() async {
        let (alice, bob, _, _) = makePair()
        alice.startOnDemand(atElapsed: 0)
        bob.startOnDemand(atElapsed: 0)
        for cue in [0.0, 10, 20] {
            alice.advance(to: cue); bob.advance(to: cue)
            await settle()
            // Guess My Answer takes two taps; the other two take one.
            while alice.currentRound?.isAcceptingInput == true { alice.choose(0) }
            while bob.currentRound?.isAcceptingInput == true { bob.choose(0) }
            await exchange(alice, bob)
        }
        alice.dismiss()

        alice.startOnDemand(atElapsed: 120)

        guard case .summary(let summary) = alice.stage else {
            return XCTFail("Expected the summary, got \(alice.stage)")
        }
        XCTAssertEqual(summary.answeredRounds, 3, "All three were played, so all three are in it")
    }

    /// Two cues can pass in one tick if the app was suspended across them.
    /// What was jumped over is recorded, not left looking live.
    func testASkippedCueIsRecordedRatherThanLeftLookingLive() async {
        let (alice, _, _, _) = makePair()
        alice.advance(to: 10)

        alice.advance(to: 30)

        XCTAssertEqual(alice.currentRound?.index, 2)
        XCTAssertEqual(alice.rounds[0].phase, .unanswered)
        XCTAssertEqual(alice.rounds[1].phase, .unanswered, "The cue nobody ever saw counts as missed")
    }

    func testAClosedRunStaysClosedWhenTheClockCarriesOn() async {
        let (alice, _, _, _) = await openFirstRound()

        alice.dismiss()
        alice.advance(to: 20)
        alice.advance(to: 40)

        XCTAssertEqual(alice.stage, .closed, "Dismissed means dismissed for the rest of the call")
    }

    func testThePeerLeavingTheRoomStopsTheCards() async {
        let (alice, _, aliceTransport, _) = await openFirstRound()

        // The room Alice is in loses its other participant.
        aliceTransport.simulatePeerLeft()
        await settle()

        XCTAssertEqual(alice.stage, .closed, "There is nobody left to answer")
    }

    /// A call whose provider has no data channel is a real, supportable
    /// state: the cards simply never appear.
    func testWithoutADataChannelNothingIsEverOffered() {
        let session = DateIcebreakerSessionModel(
            transport: nil,
            sessionID: sessionID,
            localSeat: CallGameSeat(id: aliceID, displayName: "Alice"),
            peerSeat: CallGameSeat(id: bobID, displayName: "Bob"),
            schedule: schedule,
            feedback: SilentIcebreakerFeedback()
        )
        session.begin()
        session.scheduleFromCallStart()

        session.advance(to: 10)

        XCTAssertFalse(session.isAvailable)
        XCTAssertEqual(session.stage, .idle, "No channel, no cards")
    }

    func testAForbiddenDataChannelIsTreatedAsNoChannelAtAll() {
        let (first, _) = LoopbackDataTransport.pair(aliceID, bobID)
        // The room is healthy; the token simply forbids data. A send here
        // would be dropped server-side without erroring.
        first.canSendData = false
        let session = DateIcebreakerSessionModel(
            transport: first,
            sessionID: sessionID,
            localSeat: CallGameSeat(id: aliceID, displayName: "Alice"),
            peerSeat: CallGameSeat(id: bobID, displayName: "Bob"),
            schedule: schedule,
            feedback: SilentIcebreakerFeedback()
        )
        session.scheduleFromCallStart()

        session.advance(to: 10)

        XCTAssertEqual(session.stage, .idle, "A card that could never flip is never offered")
    }

}
