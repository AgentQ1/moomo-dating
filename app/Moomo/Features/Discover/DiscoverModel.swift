import Foundation
import SwiftUI

/// Discover's state. Owns no profile data — that lives in `SessionStore`.
@MainActor
final class DiscoverModel: ObservableObject {

    enum Phase: Equatable {
        case loading
        case loaded(DiscoveryState)
        case failed(DiscoveryError)
    }

    @Published private(set) var phase: Phase = .loading

    private let service: DiscoveryService
    private var loadTask: Task<Void, Never>?

    init(service: DiscoveryService = MockDiscoveryService()) {
        self.service = service
    }

    deinit {
        loadTask?.cancel()
    }

    var state: DiscoveryState? {
        if case .loaded(let state) = phase { return state }
        return nil
    }

    func load() async {
        // Supersede any in-flight load so a pull-to-refresh during a slow load
        // can't deliver stale results after the fresh ones.
        loadTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await service.loadDiscovery()
                guard !Task.isCancelled else { return }
                phase = .loaded(state)
            } catch let error as DiscoveryError {
                guard !Task.isCancelled else { return }
                phase = .failed(error)
            } catch is CancellationError {
                // Superseded; the newer load owns the phase.
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(.offline)
            }
        }
        loadTask = task
        await task.value
    }

    // Starting calls is deliberately not here: the call flow outlives this
    // screen (it must survive tab switches), so `CallCoordinator` owns it and
    // the view hands the taps straight over.
}
