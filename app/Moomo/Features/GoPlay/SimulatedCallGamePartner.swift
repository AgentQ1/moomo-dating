#if DEBUG
import Foundation

/// A stand-in partner for the DEBUG mock world.
///
/// The mock backend has no second device, so the icebreakers would be cards
/// nobody ever answers and Go Play a picker nobody ever accepts from. This
/// sits on the far end of a `LoopbackDataTransport` and plays the part on
/// both channels: it accepts a game proposal, and it answers each icebreaker
/// with its own commit and reveal, in the right order and behind the same
/// digest the real protocol requires.
///
/// Compiled out of release builds entirely. Nothing in the shipping app has a
/// simulated partner, and the call screen already says "Simulated" whenever
/// the mock media provider is in use — a fake person must never be mistakable
/// for a real one.
final class SimulatedCallGamePartner: @unchecked Sendable {

    private let transport: LoopbackDataTransport
    private let seat: CallGameSeat
    private let lock = NSLock()
    private var sequence = 0
    /// Our own answer per round, held between the commit and the reveal.
    private var submissions: [String: (submission: IcebreakerSubmission, salt: String)] = [:]
    private var task: Task<Void, Never>?

    /// `transport` must be the far half of a `LoopbackDataTransport.pair`,
    /// with `seat.id` as its participant identity — that identity is what the
    /// local session knows the other person by.
    init(transport: LoopbackDataTransport, seat: CallGameSeat) {
        self.transport = transport
        self.seat = seat
        task = Task { [weak self, transport] in
            for await packet in transport.packets() {
                guard let self, !Task.isCancelled else { return }
                self.receive(packet)
            }
        }
    }

    deinit { task?.cancel() }

    private var identity: String { seat.id }

    private func receive(_ packet: CallDataPacket) {
        guard packet.senderID != identity else { return }
        if let lobby = CallGameCodec.decode(packet.payload) {
            handle(lobby)
        } else if let icebreaker = DateIcebreakerCodec.decode(packet.payload) {
            handle(icebreaker)
        }
    }

    // MARK: - Lobby

    private func handle(_ message: CallGameMessage) {
        guard message.kind == .invite, let game = message.game, game.isPlayable else { return }
        Task { [weak self] in
            // A beat, so accepting reads as someone answering rather than as
            // the screen changing under a finger.
            try? await Task.sleep(for: .milliseconds(900))
            guard let self else { return }
            self.send(CallGameMessage(
                sessionID: message.sessionID,
                sequence: self.nextSequence(),
                senderID: self.identity,
                kind: .accept,
                game: game,
                seat: self.seat
            ))
        }
    }

    // MARK: - Icebreakers

    private func handle(_ message: DateIcebreakerMessage) {
        switch message.kind {
        case .commit:
            answer(round: message.roundID)
        case .reveal:
            reveal(round: message.roundID)
        case .exit:
            lock.withLock { submissions.removeAll() }
        }
    }

    /// They have locked an answer in, so lock one in back. The prompt is
    /// derived from the round id exactly as the real client derives it, so
    /// the stand-in is answering the question actually on screen.
    private func answer(round roundID: String) {
        guard let prompt = Self.prompt(forRoundID: roundID) else { return }
        let alreadyAnswered = lock.withLock { submissions[roundID] != nil }
        guard !alreadyAnswered else { return }

        let submission = IcebreakerSubmission(
            choice: Int.random(in: prompt.options.indices),
            guess: prompt.kind == .guessMyAnswer ? Int.random(in: prompt.options.indices) : nil
        )
        let salt = IcebreakerCommitment.makeSalt()
        lock.withLock { submissions[roundID] = (submission, salt) }

        let digest = IcebreakerCommitment.digest(
            round: roundID, submission: submission, salt: salt
        )
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int.random(in: 600...1600)))
            guard let self else { return }
            self.send(DateIcebreakerMessage(
                roundID: roundID,
                sequence: self.nextSequence(),
                senderID: self.identity,
                kind: .commit,
                digest: digest
            ))
        }
    }

    /// They revealed, so reveal back. Never before — the stand-in plays by
    /// the same rules as a real device, or it would not be exercising them.
    private func reveal(round roundID: String) {
        guard let held = lock.withLock({ submissions[roundID] }) else { return }
        send(DateIcebreakerMessage(
            roundID: roundID,
            sequence: nextSequence(),
            senderID: identity,
            kind: .reveal,
            submission: held.submission,
            salt: held.salt
        ))
    }

    /// Round ids are `"<sessionID>#<index>"`, built identically on both
    /// devices, so the prompt can be recovered from one without asking.
    private static func prompt(forRoundID roundID: String) -> IcebreakerPrompt? {
        guard let separator = roundID.lastIndex(of: "#") else { return nil }
        let sessionID = String(roundID[roundID.startIndex..<separator])
        guard let index = Int(roundID[roundID.index(after: separator)...]) else { return nil }
        let prompts = IcebreakerDeck.prompts(forSessionID: sessionID)
        return prompts.indices.contains(index) ? prompts[index] : nil
    }

    // MARK: - Plumbing

    private func nextSequence() -> Int {
        lock.withLock {
            sequence += 1
            return sequence
        }
    }

    private func send(_ message: CallGameMessage) {
        guard let payload = try? CallGameCodec.encode(message) else { return }
        transport.deliverToPeerForTesting(payload)
    }

    private func send(_ message: DateIcebreakerMessage) {
        guard let payload = try? DateIcebreakerCodec.encode(message) else { return }
        transport.deliverToPeerForTesting(payload)
    }
}
#endif
