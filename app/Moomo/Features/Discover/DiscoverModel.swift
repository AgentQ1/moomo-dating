import Foundation
import SwiftUI
import os

/// Discover's state. Owns no profile data — that lives in `SessionStore`.
@MainActor
final class DiscoverModel: ObservableObject {

    enum Phase: Equatable {
        case loading
        case loaded(DiscoveryState)
        case failed(DiscoveryError)
    }

    @Published private(set) var phase: Phase = .loading

    private static let log = Logger(subsystem: "com.moomo.dating", category: "discovery")

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
                // Never rename an unknown failure "offline": an App Check
                // rejection or a rules/config error shown as "check your
                // connection" is a lie that hides the real fault. Classify,
                // and keep the raw error in the log.
                Self.log.error("loadDiscovery failed: \(String(describing: error), privacy: .public)")
                phase = .failed(DiscoveryErrorClassifier.classify(error))
            }
        }
        loadTask = task
        await task.value
    }

    // Starting calls is deliberately not here: the call flow outlives this
    // screen (it must survive tab switches), so `CallCoordinator` owns it and
    // the view hands the taps straight over.
}
