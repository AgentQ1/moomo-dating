import Foundation
import UIKit

/// Drives the three icebreakers across one call: when each prompt appears,
/// the commit/reveal handshake behind it, the flip, and the small summary at
/// the end.
///
/// The call is not this object's business. It never touches media, never
/// leaves or rejoins a room, and holds only a `CallDataTransport` — a
/// send-bytes/receive-bytes view onto the room the call already has. A prompt
/// appearing or being dismissed is, from the call's point of view, nothing
/// happening.
///
/// **The clock is the call's.** Nothing here runs a timer of its own for the
/// schedule: `advance(to:)` is fed the seconds elapsed in the call, which are
/// computed from the server-set session start on both devices. Two phones
/// therefore reach round two at the same moment without exchanging a word
/// about it, and a phone that was briefly suspended catches up rather than
/// drifting a round behind.
@MainActor
final class DateIcebreakerSessionModel: ObservableObject {

    enum Stage: Equatable {
        /// Nothing on screen. Before the first cue, and after the summary.
        case idle
        case round(IcebreakerRound)
        case summary(IcebreakerSummary)
        /// Closed for this call — dismissed, or the other person closed
        /// theirs. Nothing more will appear.
        case closed
    }

    // MARK: Published state

    @Published private(set) var stage: Stage = .idle
    /// True for a beat after a card flips, so the overlay can play the reveal
    /// rather than swapping the text under the reader's eyes.
    @Published private(set) var isRevealing = false
    /// A short line under the card — "they closed the cards", a reveal that
    /// didn't check out. Clears itself.
    @Published private(set) var notice: String?

    // MARK: Collaborators

    /// Nil when the call's media provider has no data channel — a real,
    /// supportable state. The prompts then never appear, because a card only
    /// one person can answer is worse than no card.
    private let transport: CallDataTransport?
    private let localSeat: CallGameSeat
    private let peerSeat: CallGameSeat
    private let schedule: IcebreakerSchedule
    private let feedback: IcebreakerFeedback

    // MARK: Session state

    /// All three rounds for this call, built up front from the session id so
    /// both devices hold the identical deck in the identical order.
    private(set) var rounds: [IcebreakerRound]
    /// Which round is on screen, if any.
    private(set) var currentIndex: Int?
    /// How many rounds have ever been opened. Distinct from `currentIndex`,
    /// which goes nil at the summary — this is what stops a tick reopening a
    /// finished round, and what a second Go Play run resumes from.
    private(set) var openedCount = 0
    /// Elapsed-seconds offset the schedule is measured from. Nil until the
    /// run starts, which is when the pair choose Icebreakers from Go Play's
    /// picker. A Video Match call never sets it, so nothing ever draws there.
    private var origin: TimeInterval?

    private var outboundSequence = 0
    /// Our own salt and digest per round, so a reveal can be sent when the
    /// moment comes and never before.
    private var localCommitments: [String: (salt: String, digest: String)] = [:]
    /// Their promise, per round. A reveal with no promise behind it is not
    /// checkable and is not shown.
    private var peerDigests: [String: String] = [:]
    /// Rounds we have already revealed on, so a duplicated commit cannot make
    /// us send our answer twice.
    private var revealedRounds: Set<String> = []
    /// Their answer, held until this side is allowed to look at it. A reveal
    /// that arrives before we have committed is parked here rather than
    /// applied: showing it would hand one person the other's answer while
    /// their own was still open, which is the one thing this design exists to
    /// prevent.
    private var pendingPeerReveals: [String: (submission: IcebreakerSubmission, salt: String)] = [:]
    /// Lifecycle messages already handled. Reliable delivery is not
    /// exactly-once delivery.
    private var handled: Set<String> = []

    private var sendChain: Task<Void, Never>?
    private var packetTask: Task<Void, Never>?
    private var participantsTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    /// How long the flip animation state stays set.
    private static let revealBeat: TimeInterval = 0.9

    init(
        transport: CallDataTransport?,
        sessionID: String,
        localSeat: CallGameSeat,
        peerSeat: CallGameSeat,
        schedule: IcebreakerSchedule = .current,
        feedback: IcebreakerFeedback = SystemIcebreakerFeedback()
    ) {
        self.transport = transport
        self.localSeat = localSeat
        self.peerSeat = peerSeat
        self.schedule = schedule
        self.feedback = feedback
        self.rounds = IcebreakerDeck.prompts(forSessionID: sessionID)
            .enumerated()
            .map { index, prompt in
                IcebreakerRound(id: "\(sessionID)#\(index)", index: index, prompt: prompt)
            }
    }

    deinit {
        sendChain?.cancel()
        packetTask?.cancel()
        participantsTask?.cancel()
        revealTask?.cancel()
        summaryTask?.cancel()
        noticeTask?.cancel()
    }

    // MARK: - Identity

    /// Whether prompts can be offered at all on this call.
    ///
    /// Both halves matter: a provider with no data channel, and a channel the
    /// room's token forbids. The second is the one that bites — a forbidden
    /// send is dropped by the server without erroring, so a card offered over
    /// such a call is a card that could never flip.
    var isAvailable: Bool { transport?.canSendData == true }

    /// Our participant identity, falling back to the seat we were built with
    /// while the room is still handing one out.
    var localPlayerID: String { transport?.localParticipantID ?? localSeat.id }

    var peerPlayerID: String { peerSeat.id }

    var peerName: String { peerSeat.displayName }

    var totalRounds: Int { rounds.count }

    /// Whether anything is on screen right now.
    var isPresenting: Bool {
        switch stage {
        case .round, .summary: true
        case .idle, .closed: false
        }
    }

    var currentRound: IcebreakerRound? {
        if case .round(let round) = stage { return round }
        return nil
    }

    // MARK: - Lifecycle

    /// Starts listening. Safe to call repeatedly; the call screen calls it on
    /// appear.
    func begin() {
        guard packetTask == nil, let transport else { return }
        packetTask = Task { [weak self, transport] in
            for await packet in transport.packets() {
                guard let self, !Task.isCancelled else { return }
                self.receive(packet)
            }
        }
        participantsTask = Task { [weak self, transport] in
            for await participants in transport.participantsStream {
                guard let self, !Task.isCancelled else { return }
                self.participantsChanged(participants)
            }
        }
    }

    /// Schedules the run from the top of the call, without anyone asking.
    ///
    /// No caller in the app: Video Match used to start the prompts this way
    /// and no longer does — the picker is the only door now. Kept, and still
    /// unit-tested, because it is the one place that defines what a
    /// call-start origin means if a future mode wants one.
    func scheduleFromCallStart() {
        guard origin == nil, isAvailable else { return }
        origin = 0
    }

    /// The run starts here instead — Go Play, where the pair chose
    /// Icebreakers from the picker partway through a call.
    ///
    /// The origin is set so the *next unplayed* cue lands now rather than in
    /// another twenty-five seconds: on Video Match the delay is the point (it
    /// lets the hellos happen first), but two people who just picked this off
    /// a list have already asked for it. The spacing between the rounds is
    /// the schedule's either way.
    ///
    /// "Next unplayed" rather than "first" because Go Play can reach here
    /// twice in one call — leave the game, pick it again. Replaying questions
    /// the two of them have already answered would be worse than not offering
    /// it, and starting from a cue that has passed would open nothing at all.
    func startOnDemand(atElapsed elapsed: TimeInterval) {
        guard isAvailable else { return }
        stage = .idle
        guard openedCount < schedule.cues.count, openedCount < rounds.count else {
            // Nothing left to ask. Show what they found rather than a blank.
            origin = elapsed - schedule.summaryAt
            advance(to: elapsed)
            return
        }
        origin = elapsed - schedule.cues[openedCount]
        advance(to: elapsed)
    }

    /// Stops listening and abandons the run. The call carries on.
    func end() {
        packetTask?.cancel(); packetTask = nil
        participantsTask?.cancel(); participantsTask = nil
        revealTask?.cancel(); revealTask = nil
        summaryTask?.cancel(); summaryTask = nil
    }

    /// Tapped the close button. The cards go away for both people — a prompt
    /// only one side can still see is a prompt the other will never answer.
    func dismiss() {
        if origin != nil, !isClosed {
            send(.init(
                roundID: currentRound?.id ?? rounds.first?.id ?? "",
                sequence: nextSequence(),
                senderID: localPlayerID,
                kind: .exit
            ))
        }
        finalizeCurrentRound()
        stage = .closed
    }

    private var isClosed: Bool { stage == .closed }

    // MARK: - The schedule

    /// Fed the seconds elapsed in the call. Opens whichever round is due,
    /// closes the one before it, and puts the summary up at the end.
    ///
    /// Deliberately idempotent and monotonic-safe: it is called once a second
    /// from the call's own clock, and calling it twice with the same value —
    /// or with a value that jumped after a suspension — must land in the same
    /// place, not replay the run.
    func advance(to elapsed: TimeInterval) {
        guard let origin, !isClosed else { return }
        let t = elapsed - origin
        guard t >= 0 else { return }

        if t >= schedule.summaryAt {
            presentSummary()
            return
        }

        guard let due = schedule.cues.lastIndex(where: { $0 <= t }), due < rounds.count else {
            return
        }
        // Only ever forwards. A clock that arrived at the same second twice,
        // or went backwards (a re-entered screen, a test winding down), must
        // not reopen a card that has already been answered.
        guard due >= openedCount else { return }
        openRound(due)
    }

    private func openRound(_ index: Int) {
        finalizeCurrentRound()
        // A cue can be skipped outright if the app was suspended across two
        // of them. Whatever was jumped over is recorded as unanswered rather
        // than left looking like a card still waiting for a tap.
        for skipped in openedCount..<index where rounds[skipped].phase != .revealed {
            rounds[skipped].phase = .unanswered
        }
        openedCount = index + 1
        currentIndex = index
        stage = .round(rounds[index])
        feedback.play(.promptArrived)
        // Anything that arrived for this round before it opened — a peer
        // whose clock was a moment ahead — is applied now rather than lost.
        drainBuffered(for: rounds[index].id)
    }

    /// A round the clock has moved past. Answered rounds keep their reveal;
    /// anything else is recorded as unanswered, blamed on nobody.
    private func finalizeCurrentRound() {
        guard let index = currentIndex else { return }
        if rounds[index].phase != .revealed {
            rounds[index].phase = .unanswered
        }
    }

    private func presentSummary() {
        guard !isClosed else { return }
        if case .summary = stage { return }
        finalizeCurrentRound()
        currentIndex = nil

        let summary = IcebreakerSummary.make(from: rounds, peerName: peerName)
        // Nothing was answered — an empty "you discovered…" card discovers
        // nothing and is worse than the screen simply going quiet.
        guard !summary.isEmpty else {
            stage = .closed
            return
        }
        stage = .summary(summary)
        feedback.play(.summary)

        summaryTask?.cancel()
        summaryTask = Task { [weak self, duration = schedule.summaryDuration] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            if case .summary = self.stage { self.stage = .closed }
        }
    }

    // MARK: - Answering

    /// Tapped one of the options.
    ///
    /// For Guess My Answer this is called twice: the first tap is the guess
    /// about them, the second is our own answer. Nothing is sent until the
    /// second — a commitment made halfway through would be a commitment to an
    /// answer that hasn't been given yet.
    func choose(_ index: Int) {
        guard case .round(var round) = stage, round.isAcceptingInput else { return }
        guard round.prompt.isValidChoice(index) else { return }

        if round.phase == .guessingPeer {
            round.stagedGuess = index
            round.phase = .answering
            commit(round)
            feedback.play(.answerLocked)
            return
        }

        let submission = IcebreakerSubmission(choice: index, guess: round.stagedGuess)
        round.local = submission
        round.phase = .waitingForPeer
        commit(round)
        feedback.play(.answerLocked)

        let salt = IcebreakerCommitment.makeSalt()
        let digest = IcebreakerCommitment.digest(
            round: round.id, submission: submission, salt: salt
        )
        localCommitments[round.id] = (salt, digest)
        send(.init(
            roundID: round.id,
            sequence: nextSequence(),
            senderID: localPlayerID,
            kind: .commit,
            digest: digest
        ))

        // They may already have promised, in which case both answers are
        // locked and the reveal can go out at once.
        revealIfBothCommitted(round.id)
    }

    /// Writes a round back into the deck and onto the screen.
    private func commit(_ round: IcebreakerRound) {
        rounds[round.index] = round
        if currentIndex == round.index { stage = .round(round) }
    }

    // MARK: - Reveal

    /// Sends our answer, but only once theirs is locked in behind a digest.
    private func revealIfBothCommitted(_ roundID: String) {
        guard let commitment = localCommitments[roundID],
              let index = rounds.firstIndex(where: { $0.id == roundID }),
              let submission = rounds[index].local,
              peerDigests[roundID] != nil,
              !revealedRounds.contains(roundID)
        else { return }

        revealedRounds.insert(roundID)
        send(.init(
            roundID: roundID,
            sequence: nextSequence(),
            senderID: localPlayerID,
            kind: .reveal,
            submission: submission,
            salt: commitment.salt
        ))
        applyPendingPeerReveal(for: roundID)
    }

    /// Their answer, checked against their promise and put on the card.
    private func applyPendingPeerReveal(for roundID: String) {
        // The gate, stated once: we look at their answer only after ours has
        // gone out, which only happens after theirs was committed.
        guard revealedRounds.contains(roundID),
              let pending = pendingPeerReveals[roundID],
              let promised = peerDigests[roundID],
              let index = rounds.firstIndex(where: { $0.id == roundID }),
              let local = rounds[index].local
        else { return }

        guard IcebreakerCommitment.verify(
            digest: promised,
            round: roundID,
            submission: pending.submission,
            salt: pending.salt
        ) else {
            pendingPeerReveals[roundID] = nil
            show(notice: "That answer didn't check out, so it's been left off.")
            return
        }

        pendingPeerReveals[roundID] = nil
        var round = rounds[index]
        round.peer = pending.submission
        round.phase = .revealed
        round.outcome = IcebreakerOutcome.make(
            prompt: round.prompt,
            local: local,
            peer: pending.submission,
            peerName: peerName
        )
        commit(round)

        // A reveal on a round the clock has already moved past changes a card
        // nobody is looking at; it is recorded, but it does not animate or
        // buzz on top of the next question.
        guard currentIndex == index else { return }
        feedback.play(round.outcome?.isAgreement == true ? .matched : .revealed)
        beginRevealAnimation()
    }

    private func beginRevealAnimation() {
        isRevealing = true
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.revealBeat))
            guard let self, !Task.isCancelled else { return }
            self.endRevealAnimation()
        }
    }

    /// Internal so a test need not sleep through the beat.
    func endRevealAnimation() {
        isRevealing = false
    }

    // MARK: - Inbound

    private func receive(_ packet: CallDataPacket) {
        // Identity comes from the transport, never from the message body: a
        // packet cannot claim to be from someone else.
        guard let senderID = packet.senderID, senderID != localPlayerID else { return }
        guard let message = DateIcebreakerCodec.decode(packet.payload) else { return }
        guard message.senderID == senderID else { return }
        guard isFirstTime(message) else { return }

        switch message.kind {
        case .commit:
            handleCommit(message)
        case .reveal:
            handleReveal(message)
        case .exit:
            handleExit()
        }
    }

    /// True the first time a given message is seen.
    private func isFirstTime(_ message: DateIcebreakerMessage) -> Bool {
        let key = "\(message.roundID)|\(message.kind.rawValue)|\(message.sequence)"
        return handled.insert(key).inserted
    }

    private func handleCommit(_ message: DateIcebreakerMessage) {
        guard !isClosed, let digest = message.digest else { return }
        guard rounds.contains(where: { $0.id == message.roundID }) else { return }
        // First promise wins. A second one for the same round would let a
        // client re-commit after seeing our reveal.
        guard peerDigests[message.roundID] == nil else { return }
        peerDigests[message.roundID] = digest
        revealIfBothCommitted(message.roundID)
    }

    private func handleReveal(_ message: DateIcebreakerMessage) {
        guard !isClosed,
              let submission = message.submission,
              let salt = message.salt,
              rounds.contains(where: { $0.id == message.roundID })
        else { return }
        guard pendingPeerReveals[message.roundID] == nil else { return }
        pendingPeerReveals[message.roundID] = (submission, salt)
        // Parked until this side has revealed too. If we haven't answered
        // yet, it stays parked — and if the clock runs the round out first,
        // it is never looked at at all.
        applyPendingPeerReveal(for: message.roundID)
    }

    private func handleExit() {
        guard !isClosed else { return }
        finalizeCurrentRound()
        stage = .closed
        show(notice: "\(peerName) closed the cards.")
    }

    // MARK: - Participants

    private func participantsChanged(_ participants: [String]) {
        guard origin != nil, !isClosed else { return }
        guard !participants.contains(peerPlayerID) else { return }
        // They are out of the room. Whatever happens to the call is the call
        // flow's business; the cards simply stop.
        finalizeCurrentRound()
        stage = .closed
    }

    // MARK: - Plumbing

    private func nextSequence() -> Int {
        outboundSequence += 1
        return outboundSequence
    }

    /// Outbound sends, chained. An unstructured task per message would let a
    /// reveal overtake the commit it is supposed to follow — and a reveal
    /// whose commitment has not landed yet is a reveal the other side has to
    /// throw away.
    private func send(_ message: DateIcebreakerMessage) {
        guard let transport, let payload = try? DateIcebreakerCodec.encode(message) else { return }
        let kind = message.kind
        let previous = sendChain
        sendChain = Task { [weak self, transport] in
            _ = await previous?.value
            do {
                try await transport.send(payload, reliable: message.needsReliableDelivery)
            } catch {
                self?.sendFailed(kind)
            }
        }
    }

    /// Awaits everything queued on the outbound chain. Internal so a test can
    /// be sure a send has actually been attempted rather than guessing how
    /// many executor hops it takes to reach the transport and back.
    func drainPendingSends() async {
        _ = await sendChain?.value
    }

    private func sendFailed(_ kind: DateIcebreakerMessageKind) {
        switch kind {
        case .commit, .reveal:
            // The card can no longer flip; say so rather than leave someone
            // waiting on an answer that never left the phone.
            show(notice: "That didn't reach \(peerName). The call's unaffected.")
        case .exit:
            break
        }
    }

    private func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.notice = nil
        }
    }

    private func drainBuffered(for roundID: String) {
        revealIfBothCommitted(roundID)
        applyPendingPeerReveal(for: roundID)
    }
}

// MARK: - Feedback

/// The haptic vocabulary of a run, behind a protocol so tests can assert on
/// it and so nothing in the model reaches for UIKit directly.
enum IcebreakerFeedbackKind: Equatable, Sendable {
    case promptArrived
    case answerLocked
    case revealed
    case matched
    case summary
}

protocol IcebreakerFeedback: Sendable {
    func play(_ kind: IcebreakerFeedbackKind)
}

/// Light and short. This runs under a live video date: a buzz here is a
/// tap on the shoulder, never an interruption.
struct SystemIcebreakerFeedback: IcebreakerFeedback {
    func play(_ kind: IcebreakerFeedbackKind) {
        Task { @MainActor in
            switch kind {
            case .promptArrived, .summary:
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            case .answerLocked:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .revealed:
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            case .matched:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}

/// Records instead of buzzing.
struct SilentIcebreakerFeedback: IcebreakerFeedback {
    func play(_ kind: IcebreakerFeedbackKind) {}
}
