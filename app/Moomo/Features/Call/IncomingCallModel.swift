import Foundation

/// The state behind the incoming-call banner: consumes the foreground ring
/// feed and decides whether a banner is up right now.
///
/// The banner's clock is the stricter of two deadlines: `ringSeconds` (the
/// product's visibility window) and the invite's own `expiresAt` (the
/// server's acceptance window). Whichever lands first takes the banner down —
/// showing an accept button the server would refuse is a lie.
@MainActor
final class IncomingCallModel: ObservableObject {

    /// The ring on screen, nil when the banner is down. Cleared by answer,
    /// decline, withdrawal (the stream yields nil), or the auto-dismiss clock.
    @Published private(set) var invite: CallInvite?

    private let calls: CallService
    /// Injectable so tests can ring for milliseconds instead of 7 seconds.
    private let ringSeconds: TimeInterval
    private var observationTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    init(calls: CallService, ringSeconds: TimeInterval = CallInvite.ringSeconds) {
        self.calls = calls
        self.ringSeconds = ringSeconds
        observationTask = Task { [weak self, calls] in
            for await invite in calls.incomingInvites() {
                guard let self, !Task.isCancelled else { return }
                self.show(invite)
            }
        }
    }

    deinit {
        observationTask?.cancel()
        dismissTask?.cancel()
    }

    private func show(_ invite: CallInvite?) {
        dismissTask?.cancel()
        self.invite = invite
        guard let invite else { return }

        // Auto-dismiss at the earlier deadline. A no-response ring simply
        // times out — the server sweeps it to "expired"; nothing to send.
        let window = min(ringSeconds, invite.expiresAt.timeIntervalSinceNow)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, window)))
            guard !Task.isCancelled else { return }
            self?.invite = nil
        }
    }

    /// The user tapped accept: the banner comes down and the invite is handed
    /// to the caller (the coordinator), whose flow runs the actual accept.
    /// Nil when the ring vanished under the tap.
    func accept() -> CallInvite? {
        guard let invite else { return nil }
        dismissTask?.cancel()
        self.invite = nil
        return invite
    }

    /// The user said no: the banner comes down immediately, and the decline
    /// reaches the backend best-effort — like leaving the queue, a decline
    /// that never lands just expires server-side.
    func decline() {
        guard let invite else { return }
        dismissTask?.cancel()
        self.invite = nil
        Task { [calls] in
            await calls.declineInvite(invite)
        }
    }
}
