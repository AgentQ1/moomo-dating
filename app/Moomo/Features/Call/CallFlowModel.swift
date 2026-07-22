import Foundation
import SwiftUI
import UIKit

/// Why a flow ended on the failure screen, and whether Settings can fix it.
struct CallFailure: Equatable, Sendable {
    var message: String
    var isPermissionDenied = false
}

/// One matchmaking-to-decision journey: permissions → search → connect →
/// media → live call → like/pass → (maybe) match. Owns the countdown clock
/// and every transition; the views under `CallFlowView` render its stage and
/// call back into it.
@MainActor
final class CallFlowModel: ObservableObject {

    enum Stage: Equatable {
        case searching
        case connecting(DiscoveryCandidate)
        case active(CallSession)
        /// Call over; waiting on the local like/pass.
        case deciding(CallSummary)
        /// Liked, not mutual. Terminal.
        case likeSent(CallSummary)
        /// Mutual like. Terminal.
        case matched(Match)
        /// Permissions, search, connect, or media failed. Terminal.
        case failed(CallFailure)
    }

    @Published private(set) var stage: Stage = .searching {
        didSet {
            // The screen must not sleep on someone mid-call; everywhere else
            // the system idle timer is restored immediately.
            if case .active = stage {
                holdsIdleTimer = true
                setIdleTimerDisabled(true)
            } else if case .active = oldValue {
                holdsIdleTimer = false
                setIdleTimerDisabled(false)
            }
        }
    }
    /// Mirror of "stage is .active" that `deinit` (nonisolated) may read to
    /// give the idle timer back when a live call's flow is torn down.
    private nonisolated(unsafe) var holdsIdleTimer = false
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var isMuted = false
    @Published private(set) var isCameraOn: Bool
    /// The media transport's state, for the in-call status line
    /// (connecting/reconnecting) — distinct from the flow's stage.
    @Published private(set) var mediaState: CallMediaState = .idle
    @Published private(set) var isSubmittingDecision = false
    /// Set after a report goes through, so the call UI can confirm it.
    @Published private(set) var didSubmitReport = false
    /// A safety action (block, report), decision, or control that failed to
    /// reach the backend. Shown where the action was attempted; nil once one
    /// succeeds.
    @Published private(set) var actionFailure: String?

    let mode: CallMode
    /// Exposed for the call screen, which renders provider video tracks.
    let media: CallMediaService

    private let preferred: DiscoveryCandidate?
    private let calls: CallService
    private let matches: MatchService
    private let safety: SafetyService
    private let permissions: CallPermissionsChecking
    /// Overridable so the timer-expiry path is testable in seconds, not minutes.
    private let callDuration: TimeInterval
    /// How long an active call waits for the other person to appear in the
    /// media room before deciding nobody is coming. Overridable for tests.
    private let peerJoinTimeout: TimeInterval
    /// The flow is finished (cancelled, passed, matched, dismissed) — the
    /// coordinator tears it down.
    private let onFinished: () -> Void
    /// Injectable so tests can observe it; `@Sendable` so `deinit` (which may
    /// run off the main actor) can restore the timer for a torn-down live call.
    private let setIdleTimerDisabled: @Sendable (Bool) -> Void

    private var setupTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var mediaWatchTask: Task<Void, Never>?
    private var peerEndWatchTask: Task<Void, Never>?
    private var ghostWatchTask: Task<Void, Never>?

    init(
        mode: CallMode,
        preferred: DiscoveryCandidate? = nil,
        calls: CallService,
        matches: MatchService,
        safety: SafetyService,
        media: CallMediaService,
        permissions: CallPermissionsChecking = SystemCallPermissions(),
        callDuration: TimeInterval = CallSession.speedCallDuration,
        peerJoinTimeout: TimeInterval = 15,
        setIdleTimerDisabled: @escaping @Sendable (Bool) -> Void = { disabled in
            Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = disabled }
        },
        onFinished: @escaping () -> Void
    ) {
        self.mode = mode
        self.preferred = preferred
        self.calls = calls
        self.matches = matches
        self.safety = safety
        self.media = media
        self.permissions = permissions
        self.callDuration = callDuration
        self.peerJoinTimeout = peerJoinTimeout
        self.setIdleTimerDisabled = setIdleTimerDisabled
        self.onFinished = onFinished
        self.isCameraOn = mode == .video
    }

    deinit {
        setupTask?.cancel()
        timerTask?.cancel()
        mediaWatchTask?.cancel()
        peerEndWatchTask?.cancel()
        ghostWatchTask?.cancel()
        // A flow torn down mid-call (sign-out under a minimised call) must
        // still give the idle timer back.
        if holdsIdleTimer { setIdleTimerDisabled(false) }
        // The room must not outlive the flow that joined it.
        Task { [media] in await media.leave() }
    }

    var candidate: DiscoveryCandidate? {
        switch stage {
        case .searching: preferred
        case .connecting(let candidate): candidate
        case .active(let session): session.candidate
        case .deciding(let summary), .likeSent(let summary): summary.candidate
        case .matched(let match): match.candidate
        case .failed: nil
        }
    }

    // MARK: - Search & connect

    func start() {
        guard case .searching = stage, setupTask == nil else { return }
        setupTask = Task { [weak self] in
            guard let self else { return }

            // Permission gate before matchmaking: pairing a real person with
            // someone whose microphone can never open wastes their time.
            guard await permissions.ensurePermissions(for: mode) else {
                stage = .failed(Self.permissionFailure(for: mode))
                return
            }

            do {
                let candidate = try await calls.findCandidate(mode: mode, preferring: preferred)
                guard !Task.isCancelled else { return }
                stage = .connecting(candidate)

                let session = try await calls.connect(to: candidate, mode: mode)
                guard !Task.isCancelled else { return }
                var timedSession = session
                if callDuration != session.maxDuration {
                    timedSession = CallSession(
                        id: session.id,
                        candidate: session.candidate,
                        mode: session.mode,
                        startedAt: session.startedAt,
                        maxDuration: callDuration
                    )
                }

                // Media joins during "connecting": the call is only active
                // once audio can actually flow.
                watchMedia()
                do {
                    try await media.join(session: timedSession)
                } catch {
                    guard !Task.isCancelled else { return }
                    await failWithoutMedia(timedSession, error: error)
                    return
                }
                guard !Task.isCancelled else {
                    // Cancelled while the room was connecting — don't stay in it.
                    await media.leave()
                    return
                }

                stage = .active(timedSession)
                startClock(for: timedSession)
                watchPeerEnd(of: timedSession)
                watchForEmptyRoom(of: timedSession)
            } catch is CancellationError {
                // Cancelled search; the coordinator already tore us down.
            } catch let error as CallServiceError {
                guard !Task.isCancelled else { return }
                stage = .failed(CallFailure(message: error.errorDescription ?? "Please try again."))
            } catch {
                guard !Task.isCancelled else { return }
                stage = .failed(CallFailure(message: "Something went wrong. Please try again."))
            }
        }
    }

    /// Media never came up. End the server session honestly (the peer's
    /// client learns and moves on) and tell the user — never a silent room.
    private func failWithoutMedia(_ session: CallSession, error: Error) async {
        mediaWatchTask?.cancel()
        await media.leave()

        let duration = max(0, min(Date().timeIntervalSince(session.startedAt), session.maxDuration))
        await calls.record(CallRecord(
            id: session.id,
            candidate: session.candidate,
            mode: session.mode,
            startedAt: session.startedAt,
            duration: duration,
            endReason: .ended,
            outcome: .undecided
        ))

        let message = (error as? LocalizedError)?.errorDescription
            ?? CallMediaError.connectFailed.errorDescription
            ?? "Please try again."
        stage = .failed(CallFailure(message: message))
    }

    static func permissionFailure(for mode: CallMode) -> CallFailure {
        switch mode {
        case .voice:
            CallFailure(
                message: "Baybe needs microphone access for voice calls. You can turn it on in Settings.",
                isPermissionDenied: true
            )
        case .video:
            CallFailure(
                message: "Baybe needs microphone and camera access for video calls. You can turn them on in Settings.",
                isPermissionDenied: true
            )
        }
    }

    /// Backing out of the search (or a failed search).
    func cancel() {
        setupTask?.cancel()
        timerTask?.cancel()
        mediaWatchTask?.cancel()
        peerEndWatchTask?.cancel()
        ghostWatchTask?.cancel()
        Task { [media] in await media.leave() }
        onFinished()
    }

    // MARK: - Media

    private func watchMedia() {
        mediaWatchTask = Task { [weak self, media] in
            for await state in media.stateStream {
                guard let self, !Task.isCancelled else { return }
                self.mediaState = state
                // A transport that died for good mid-call ends the call —
                // two people in a dead room is not a call.
                if case .disconnected = state, case .active = self.stage {
                    self.endCall(reason: .ended)
                }
            }
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    private func setMuted(_ muted: Bool) {
        let previous = isMuted
        isMuted = muted
        Task { [weak self, media] in
            do {
                try await media.setMuted(muted)
            } catch {
                // The button must never claim a state the microphone isn't in.
                guard let self else { return }
                self.isMuted = previous
                self.actionFailure = "Couldn't update the microphone. Please try again."
            }
        }
    }

    func toggleCamera() {
        let previous = isCameraOn
        isCameraOn.toggle()
        let enabled = isCameraOn
        Task { [weak self, media] in
            do {
                try await media.setCameraEnabled(enabled)
            } catch {
                guard let self else { return }
                self.isCameraOn = previous
                self.actionFailure = "Couldn't update the camera. Please try again."
            }
        }
    }

    // MARK: - The clock

    private func startClock(for session: CallSession) {
        // Always recomputed from the session's start, never decremented: the
        // server started the clock at pairing, per-tick sleeps overshoot, and
        // background suspension stops ticks entirely — a local countdown
        // drifts away from the server's (and the peer's) clock.
        remainingSeconds = Self.remainingSeconds(in: session, now: Date())
        timerTask = Task { [weak self] in
            while let self, self.remainingSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.remainingSeconds = Self.remainingSeconds(in: session, now: Date())
            }
            self?.endCall(reason: .timeExpired)
        }
    }

    /// Wall-clock remaining time for `session` at `now`.
    static func remainingSeconds(in session: CallSession, now: Date) -> Int {
        max(0, Int((session.maxDuration - now.timeIntervalSince(session.startedAt)).rounded()))
    }

    var formattedRemaining: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    // MARK: - Ending

    func endCall(reason: CallEndReason = .ended) {
        guard case .active(let session) = stage else { return }
        timerTask?.cancel()
        peerEndWatchTask?.cancel()
        mediaWatchTask?.cancel()
        ghostWatchTask?.cancel()
        Task { [media] in await media.leave() }

        let duration = min(
            Date().timeIntervalSince(session.startedAt),
            session.maxDuration
        )
        // The record's id IS the session's id: the live service ends the
        // server-side `callSessions` document by it, and history is the
        // backend's per-user projection keyed the same way.
        let record = CallRecord(
            id: session.id,
            candidate: session.candidate,
            mode: session.mode,
            startedAt: session.startedAt,
            duration: duration,
            endReason: reason,
            outcome: reason == .blocked ? .blocked : .undecided
        )
        Task { [calls] in await calls.record(record) }

        stage = .deciding(CallSummary(
            candidate: session.candidate,
            mode: session.mode,
            duration: duration,
            endReason: reason,
            recordID: record.id
        ))
    }

    /// The server ended the session (peer hung up or blocked — told apart by
    /// nobody). History is already written server-side; recording again would
    /// double-end the session.
    private func watchPeerEnd(of session: CallSession) {
        peerEndWatchTask = Task { [weak self, calls] in
            for await reason in calls.endEvents(for: session.id) {
                guard let self, !Task.isCancelled else { return }
                guard case .active = self.stage else { return }
                self.timerTask?.cancel()
                self.mediaWatchTask?.cancel()
                self.ghostWatchTask?.cancel()
                Task { [media = self.media] in await media.leave() }

                let duration = min(
                    Date().timeIntervalSince(session.startedAt),
                    session.maxDuration
                )
                self.stage = .deciding(CallSummary(
                    candidate: session.candidate,
                    mode: session.mode,
                    duration: duration,
                    endReason: reason,
                    recordID: session.id
                ))
                return
            }
        }
    }

    // MARK: - Empty room

    /// Nobody ever entered the room: the pairing was a ghost — their app died
    /// (or walked away) between queueing and connecting. Rather than three
    /// minutes of silence, the call ends honestly once `peerJoinTimeout`
    /// passes with no one there. A peer who arrives in time disarms it.
    private func watchForEmptyRoom(of session: CallSession) {
        ghostWatchTask = Task { [weak self, media, peerJoinTimeout] in
            let arrived = await Self.peerArrived(
                on: media.remotePresenceStream,
                within: peerJoinTimeout
            )
            guard let self, !Task.isCancelled, !arrived else { return }
            self.abandonEmptyCall(session)
        }
    }

    /// True the moment presence turns true; false once `timeout` passes first.
    private static func peerArrived(
        on presence: AsyncStream<Bool>,
        within timeout: TimeInterval
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await present in presence where present {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    /// Tears the call down like an end, but lands on the failure screen —
    /// there is nobody to decide about.
    private func abandonEmptyCall(_ session: CallSession) {
        guard case .active = stage else { return }
        timerTask?.cancel()
        peerEndWatchTask?.cancel()
        mediaWatchTask?.cancel()
        Task { [media] in await media.leave() }

        // Close the server session: the no-show's client (if it ever wakes)
        // learns the call is over, and the session can't be joined late.
        let duration = min(Date().timeIntervalSince(session.startedAt), session.maxDuration)
        Task { [calls] in
            await calls.record(CallRecord(
                id: session.id,
                candidate: session.candidate,
                mode: session.mode,
                startedAt: session.startedAt,
                duration: duration,
                endReason: .ended,
                outcome: .undecided
            ))
        }

        stage = .failed(CallFailure(
            message: "\(session.candidate.displayName) couldn't make it into the call. Try another search."
        ))
    }

    // MARK: - Decision

    func decide(_ decision: UserDecision) async {
        guard case .deciding(let summary) = stage, !isSubmittingDecision else { return }
        isSubmittingDecision = true
        defer { isSubmittingDecision = false }

        do {
            let outcome = try await matches.submitDecision(
                decision,
                about: summary.candidate,
                // recordID is the call session id; the backend verifies the
                // decision belongs to a call we were actually in.
                callSessionID: summary.recordID
            )
            actionFailure = nil
            switch outcome {
            case .passed:
                await calls.setOutcome(.passed, forRecord: summary.recordID)
                onFinished()
            case .likeSent:
                await calls.setOutcome(.liked, forRecord: summary.recordID)
                stage = .likeSent(summary)
            case .matched(let match):
                await calls.setOutcome(.matched, forRecord: summary.recordID)
                stage = .matched(match)
            }
        } catch {
            // Stay on the decision screen with retryable copy — the choice
            // hasn't been recorded, and silently pretending otherwise would
            // invent a decision.
            actionFailure = (error as? LocalizedError)?.errorDescription
                ?? "That didn't go through. Please try again."
        }
    }

    /// Leaves a terminal stage (likeSent, matched via "Keep browsing", failed).
    func finish() {
        onFinished()
    }

    // MARK: - Safety

    /// Blocks the current person. Ends the call if one is running, then
    /// finishes the flow — there is nothing to decide about someone blocked.
    ///
    /// If the block cannot be recorded, the flow does NOT finish: walking
    /// away as if it worked would leave the user believing someone is gone
    /// who isn't.
    func blockAndFinish() async {
        guard let candidate else { return }

        do {
            try await safety.block(candidate)
        } catch {
            actionFailure = "Couldn't block \(candidate.displayName). Check your connection and try again."
            return
        }
        actionFailure = nil

        if case .active = stage {
            endCall(reason: .blocked)
        }
        if case .deciding(let summary) = stage {
            await calls.setOutcome(.blocked, forRecord: summary.recordID)
        }
        onFinished()
    }

    /// Reports the current person. The call (if any) keeps running — whether
    /// to also block or end is the user's choice, offered alongside.
    /// `didSubmitReport` flips only when the report actually landed.
    func submitReport(reason: ReportReason, details: String?) async {
        guard let candidate else { return }
        do {
            try await safety.report(candidate, reason: reason, details: details)
            didSubmitReport = true
            actionFailure = nil
        } catch {
            actionFailure = "Your report couldn't be sent. Check your connection and try again."
        }
    }
}
