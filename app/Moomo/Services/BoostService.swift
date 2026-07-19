import Foundation

/// Boost state: a timed visibility bump.
struct BoostState: Equatable, Sendable {
    /// When the running boost ends. Nil or past means not boosted.
    var activeUntil: Date?
    /// Boosts left to use. Free during the beta — there is no StoreKit yet,
    /// and nothing anywhere may imply payment until there is.
    var remainingBoosts: Int

    func isActive(now: Date = Date()) -> Bool {
        guard let activeUntil else { return false }
        return activeUntil > now
    }
}

protocol BoostService: Sendable {
    /// Opens with the current state; re-emits on every change.
    var stateStream: AsyncStream<BoostState> { get }

    func state() async -> BoostState

    /// Starts a boost. Throws if one is already running or none are left.
    @discardableResult
    func activate() async throws -> BoostState
}

enum BoostError: LocalizedError, Equatable {
    case alreadyActive
    case noneRemaining

    var errorDescription: String? {
        switch self {
        case .alreadyActive: "You're already boosted."
        case .noneRemaining: "No boosts left. More arrive tomorrow."
        }
    }
}

/// In-memory boost. Activation flips real state with a real expiry; nothing
/// pretends to charge anyone.
final class MockBoostService: BoostService, @unchecked Sendable {

    private let broadcaster: StreamBroadcaster<BoostState>
    private let boostDuration: TimeInterval
    private let now: @Sendable () -> Date

    init(
        initialBoosts: Int = 3,
        boostDuration: TimeInterval = 30 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.boostDuration = boostDuration
        self.now = now
        broadcaster = StreamBroadcaster(
            BoostState(activeUntil: nil, remainingBoosts: initialBoosts)
        )
    }

    var stateStream: AsyncStream<BoostState> { broadcaster.stream() }

    func state() async -> BoostState { broadcaster.value }

    @discardableResult
    func activate() async throws -> BoostState {
        let current = broadcaster.value
        if current.isActive(now: now()) { throw BoostError.alreadyActive }
        guard current.remainingBoosts > 0 else { throw BoostError.noneRemaining }

        let next = BoostState(
            activeUntil: now().addingTimeInterval(boostDuration),
            remainingBoosts: current.remainingBoosts - 1
        )
        broadcaster.send(next)
        return next
    }
}
