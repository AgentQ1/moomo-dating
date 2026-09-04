import Foundation
import UIKit

/// Go Play's lobby, inside a live call: opening the picker, proposing a game,
/// answering someone else's proposal, and putting the chosen game on screen.
///
/// Go Play is deliberately a *mode* rather than a game. Two people match on
/// video first and then decide together what to do, so the thing that has to
/// be right is the decision, not any one game's rules — and the decision is
/// what this object owns. Adding Snake Clash or Ludo later means adding a
/// case to `CallGame` and a view to render it; the invite/accept/decline
/// handshake, the duplicate handling, the timeouts, and the leaving are
/// already here and already tested.
///
/// The call is not this object's business. It never touches media, never
/// leaves or rejoins a room, and holds only a `CallDataTransport` — a
/// send-bytes/receive-bytes view onto the room the call already has. Opening
/// the picker, starting a game, and walking out of one are, from the call's
/// point of view, nothing happening.
@MainActor
final class GoPlaySessionModel: ObservableObject {

    enum Stage: Equatable {
        /// The call is just a call.
        case idle
        /// The list is open on this side. Purely local — the other person is
        /// told nothing until something is actually proposed.
        case picking
        /// We proposed; waiting on them.
        case invitePending(CallGame)
        /// They proposed; waiting on us.
        case inviteReceived(CallGame)
        /// Agreed. The game owns its own screen from here.
        case playing(CallGame)
    }

    // MARK: Published state

    @Published private(set) var stage: Stage = .idle
    /// A short line under the controls — "they said no", "nobody answered".
    /// Clears itself.
    @Published private(set) var notice: String?

    // MARK: Collaborators

    /// Nil when the call's media provider has no data channel — a real,
    /// supportable state. Go Play then never offers the picker, because a
    /// game only one person can see is worse than no game.
    private let transport: CallDataTransport?
    private let localSeat: CallGameSeat
    private let peerSeat: CallGameSeat
    private let feedback: IcebreakerFeedback

    // MARK: Session state

    private var sessionID: String?
    private var outboundSequence = 0
    /// Messages already handled, per game session. Reliable delivery is not
    /// exactly-once delivery, and acting on a duplicated accept would open
    /// two games.
    private var handled: Set<String> = []

    private var sendChain: Task<Void, Never>?
    private var packetTask: Task<Void, Never>?
    private var participantsTask: Task<Void, Never>?
    private var invitationTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    /// How long a proposal stays pending before giving up. Someone who has
    /// not answered in this long is not about to, and a spinner with no end
    /// is worse than an honest "no answer".
    private static let invitationTimeout: TimeInterval = 30

    init(
        transport: CallDataTransport?,
        localSeat: CallGameSeat,
        peerSeat: CallGameSeat,
        feedback: IcebreakerFeedback = SystemIcebreakerFeedback()
    ) {
        self.transport = transport
        self.localSeat = localSeat
        self.peerSeat = peerSeat
        self.feedback = feedback
    }

    deinit {
        sendChain?.cancel()
        packetTask?.cancel()
        participantsTask?.cancel()
        invitationTask?.cancel()
        noticeTask?.cancel()
    }

    // MARK: - Identity

    /// Whether a game can be offered at all on this call.
    ///
    /// Both halves matter: a provider with no data channel, and a channel the
    /// room's token forbids. The second is the one that bites — a forbidden
    /// send is dropped by the server without erroring, so a picker over such
    /// a call is a picker whose invitations silently go nowhere.
    var isAvailable: Bool { transport?.canSendData == true }

    var localPlayerID: String { transport?.localParticipantID ?? localSeat.id }

    var peerPlayerID: String { peerSeat.id }

    var peerName: String { peerSeat.displayName }

    /// True while the picker or an invitation is on screen — the call is
    /// still the thing being looked at.
    var isChoosing: Bool {
        switch stage {
        case .picking, .invitePending, .inviteReceived: true
        case .idle, .playing: false
        }
    }

    /// The game currently being played, if any. The call screen renders it.
    var activeGame: CallGame? {
        if case .playing(let game) = stage { return game }
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

    /// Stops listening and abandons anything in flight. The call carries on.
    func end() {
        packetTask?.cancel(); packetTask = nil
        participantsTask?.cancel(); participantsTask = nil
        teardown()
    }

    // MARK: - The picker

    /// Tapped Games. Opening the list tells the other person nothing — a
    /// browse is not an offer.
    func openPicker() {
        guard isAvailable, stage == .idle else { return }
        stage = .picking
        notice = nil
    }

    /// Backed out of the list without choosing.
    func closePicker() {
        guard stage == .picking else { return }
        stage = .idle
    }

    /// Chose a game from the list. Unbuilt games are refused here as well as
    /// disabled in the view: the picker is not the only thing that can reach
    /// this, and "coming soon" has to mean it everywhere.
    func propose(_ game: CallGame) {
        guard isAvailable, game.isPlayable else { return }
        switch stage {
        case .idle, .picking: break
        case .invitePending, .inviteReceived, .playing: return
        }

        let id = UUID().uuidString
        sessionID = id
        handled.removeAll()
        stage = .invitePending(game)
        notice = nil
        send(.init(
            sessionID: id,
            sequence: nextSequence(),
            senderID: localPlayerID,
            kind: .invite,
            game: game,
            seat: localSeat
        ))
        armInvitationTimeout()
    }

    /// Said yes to their proposal.
    func acceptInvite() {
        guard case .inviteReceived(let game) = stage, let id = sessionID else { return }
        send(.init(
            sessionID: id,
            sequence: nextSequence(),
            senderID: localPlayerID,
            kind: .accept,
            game: game,
            seat: localSeat
        ))
        stage = .playing(game)
    }

    /// Said no. The call is untouched.
    func declineInvite() {
        guard case .inviteReceived = stage, let id = sessionID else { return }
        send(.init(
            sessionID: id,
            sequence: nextSequence(),
            senderID: localPlayerID,
            kind: .decline
        ))
        sessionID = nil
        stage = .idle
    }

    /// Left the game (or cancelled a proposal). Tells the other person, then
    /// puts the ordinary call back on screen. The call itself is never
    /// touched — no room is left, nothing is republished.
    func leaveGame() {
        if let id = sessionID {
            send(.init(
                sessionID: id,
                sequence: nextSequence(),
                senderID: localPlayerID,
                kind: .exit
            ))
        }
        teardown()
    }

    private func armInvitationTimeout() {
        invitationTask?.cancel()
        invitationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.invitationTimeout))
            guard let self, !Task.isCancelled else { return }
            self.invitationTimedOut()
        }
    }

    /// Internal so a test need not wait thirty seconds for it.
    func invitationTimedOut() {
        guard case .invitePending = stage else { return }
        // Best effort: withdraw the offer, so their card comes down too
        // rather than answering into a game we have given up on.
        if let id = sessionID {
            send(.init(
                sessionID: id,
                sequence: nextSequence(),
                senderID: localPlayerID,
                kind: .exit
            ))
        }
        teardown()
        show(notice: "\(peerName) didn't answer.")
    }

    // MARK: - Inbound

    private func receive(_ packet: CallDataPacket) {
        // Identity comes from the transport, never from the message body: a
        // packet cannot claim to be from someone else.
        guard let senderID = packet.senderID, senderID != localPlayerID else { return }
        guard let message = CallGameCodec.decode(packet.payload) else { return }
        guard message.senderID == senderID else { return }

        switch message.kind {
        case .invite:
            handleInvite(message, from: senderID)
        case .accept:
            handleAccept(message)
        case .decline:
            handleDecline(message)
        case .exit:
            handleExit(message)
        }
    }

    /// True the first time a given message is seen.
    private func isFirstTime(_ message: CallGameMessage) -> Bool {
        let key = "\(message.sessionID)|\(message.kind.rawValue)|\(message.sequence)"
        return handled.insert(key).inserted
    }

    /// Belongs to the game we are actually in.
    private func isCurrent(_ message: CallGameMessage) -> Bool {
        message.sessionID == sessionID
    }

    private func handleInvite(_ message: CallGameMessage, from senderID: String) {
        guard let game = message.game else { return }
        // A build that has never heard of this game, or one that knows it
        // isn't finished, refuses rather than opening an empty screen.
        guard game.isPlayable else { return }

        switch stage {
        case .idle, .picking:
            break
        case .invitePending:
            // Both proposed at once. Rather than two games, the lower
            // participant identity's proposal is the one that stands — a rule
            // both devices evaluate from the same two strings, so they reach
            // the same answer with no further round trip.
            guard senderID < localPlayerID else { return }
        case .inviteReceived, .playing:
            return
        }

        invitationTask?.cancel(); invitationTask = nil
        sessionID = message.sessionID
        handled.removeAll()
        _ = isFirstTime(message)
        notice = nil
        stage = .inviteReceived(game)
        feedback.play(.promptArrived)
    }

    private func handleAccept(_ message: CallGameMessage) {
        guard case .invitePending(let game) = stage, isCurrent(message), isFirstTime(message) else {
            return
        }
        invitationTask?.cancel(); invitationTask = nil
        stage = .playing(game)
    }

    private func handleDecline(_ message: CallGameMessage) {
        guard case .invitePending = stage, isCurrent(message), isFirstTime(message) else { return }
        invitationTask?.cancel(); invitationTask = nil
        sessionID = nil
        // Straight back to the list: they said no to *that* game, not to
        // playing at all.
        stage = .picking
        show(notice: "\(peerName) picked something else — try another.")
    }

    private func handleExit(_ message: CallGameMessage) {
        guard isCurrent(message), isFirstTime(message), stage != .idle else { return }
        let wasPlaying = activeGame != nil
        teardown()
        show(notice: wasPlaying
            ? "\(peerName) went back to the call."
            : "\(peerName) called that off.")
    }

    // MARK: - Participants

    private func participantsChanged(_ participants: [String]) {
        guard stage != .idle else { return }
        guard !participants.contains(peerPlayerID) else { return }
        // They are out of the room. Whatever happens to the call is the call
        // flow's business; the game simply stops.
        teardown()
        show(notice: "\(peerName) left.")
    }

    private func teardown() {
        invitationTask?.cancel(); invitationTask = nil
        sessionID = nil
        handled.removeAll()
        stage = .idle
    }

    // MARK: - Plumbing

    private func nextSequence() -> Int {
        outboundSequence += 1
        return outboundSequence
    }

    /// Outbound sends, chained. An unstructured task per message would let an
    /// accept overtake the invite it answers; reliable delivery preserves
    /// order on the wire, so the client must not lose it before that.
    private func send(_ message: CallGameMessage) {
        guard let transport, let payload = try? CallGameCodec.encode(message) else { return }
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

    /// A message could not be sent. Undo whatever it was about to start, and
    /// say so — a proposal stuck on the phone leaves someone watching a
    /// spinner for an answer that was never asked for.
    private func sendFailed(_ kind: CallGameMessageKind) {
        switch kind {
        case .invite:
            guard case .invitePending = stage else { return }
            teardown()
            show(notice: "Couldn't reach \(peerName) to start a game.")
        case .accept:
            guard activeGame != nil else { return }
            teardown()
            show(notice: "The game couldn't start. You're still on the call.")
        case .decline, .exit:
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
}
