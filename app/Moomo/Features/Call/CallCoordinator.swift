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
    func start(mode: CallMode, with candidate: DiscoveryCandidate? = nil) {
        if flow != nil {
            isPresenting = true
            return
        }
        let flow = CallFlowModel(
            mode: mode,
            preferred: candidate,
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
