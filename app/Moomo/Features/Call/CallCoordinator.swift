import Combine
import Foundation
import SwiftUI

/// Owns the call flow above the tabs, so a call survives tab switches and can
/// be minimised and re-entered (Calls tab, Discover banner).
@MainActor
final class CallCoordinator: ObservableObject {

    @Published private(set) var flow: CallFlowModel?
    /// Drives the full-screen cover. False with a live `flow` means the call
    /// is minimised and still running.
    @Published var isPresenting = false

    private var stageObservation: AnyCancellable?

    /// Wired by the tab shell: switch to Chat and open this conversation.
    /// A closure because the coordinator must not know about tab state.
    var openConversation: ((String) -> Void)?

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var hasActiveCall: Bool {
        if case .active = flow?.stage { return true }
        return false
    }

    var hasMinimisedCall: Bool {
        hasActiveCall && !isPresenting
    }

    /// Starts matchmaking — or, if a call is already running, returns to it
    /// instead. Two concurrent calls is never a thing.
    ///
    /// An unsupported mode is refused outright rather than quietly upgraded:
    /// the only way a `.voice` start can reach here now is a caller that was
    /// missed when Speed Talk was removed, and silently handing that caller a
    /// video call would hide the bug instead of surfacing it.
    func start(
        mode: CallMode,
        with candidate: DiscoveryCandidate? = nil,
        experience: CallExperience = .videoMatch
    ) {
        guard mode.isSupported else {
            assertionFailure("Refused a call in the retired \(mode.rawValue) mode.")
            return
        }
        if flow != nil {
            isPresenting = true
            return
        }
        let flow = CallFlowModel(
            mode: mode,
            preferred: candidate,
            experience: experience,
            calls: services.calls,
            matches: services.matches,
            safety: services.safety,
            media: services.media,
            permissions: services.callPermissions,
            onFinished: { [weak self] in self?.finish() }
        )
        self.flow = flow
        observeStage(of: flow)
        isPresenting = true
        flow.start()
    }

    /// Answers an incoming ring: builds the flow around the accepted invite
    /// and presents it. With a call already running the invite is ignored —
    /// the banner is suppressed while a flow exists, so arriving here busy
    /// means a race the running call wins; two concurrent calls is never a
    /// thing.
    func acceptIncoming(_ invite: CallInvite) {
        guard flow == nil else { return }
        // A ring in the retired voice-only mode is never answerable. The
        // banner already refuses to show one (`IncomingCallModel`); this is
        // the backstop for anything that reaches the coordinator directly.
        guard invite.mode.isSupported else { return }
        let flow = CallFlowModel(
            mode: invite.mode,
            incoming: invite,
            calls: services.calls,
            matches: services.matches,
            safety: services.safety,
            media: services.media,
            permissions: services.callPermissions,
            onFinished: { [weak self] in self?.finish() }
        )
        self.flow = flow
        observeStage(of: flow)
        isPresenting = true
        flow.start()
    }

    /// A minimised call whose stage leaves `.active` must come back on
    /// screen: the like/pass decision (or the failure) would otherwise be
    /// stranded behind the tabs — the banner only advertises *active* calls,
    /// so an ended-while-minimised call had no way back at all.
    private func observeStage(of flow: CallFlowModel) {
        stageObservation = flow.$stage.sink { [weak self] stage in
            guard let self, !self.isPresenting else { return }
            switch stage {
            case .deciding, .likeSent, .matched, .failed:
                self.isPresenting = true
            case .searching, .connecting, .active:
                break
            }
        }
    }

    /// Hides the call UI without ending the call.
    func minimise() {
        isPresenting = false
    }

    /// Re-enters a minimised call.
    func resume() {
        guard flow != nil else { return }
        isPresenting = true
    }

    private func finish() {
        stageObservation = nil
        isPresenting = false
        flow = nil
    }
}
