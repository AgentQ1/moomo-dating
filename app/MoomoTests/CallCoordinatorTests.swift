import XCTest
@testable import Moomo

/// The coordinator's single-call guarantee and minimise/re-enter behaviour —
/// what the Calls tab's "return to call" row and Discover's banner rely on.
@MainActor
final class CallCoordinatorTests: XCTestCase {

    private func settle(_ ms: UInt64 = 150) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    private func makeCoordinator() -> CallCoordinator {
        // The wired mock graph, exactly as the app builds it. Mock latencies
        // are real but short enough to await in a test.
        CallCoordinator(services: .mock())
    }

    func testStartCreatesAndPresentsOneFlow() async {
        let coordinator = makeCoordinator()

        coordinator.start(mode: .voice)

        XCTAssertNotNil(coordinator.flow)
        XCTAssertTrue(coordinator.isPresenting)
        XCTAssertEqual(coordinator.flow?.mode, .voice)
    }

    func testSecondStartReturnsToTheRunningCallInsteadOfStackingOne() async {
        let coordinator = makeCoordinator()
        coordinator.start(mode: .voice)
        let first = coordinator.flow

        coordinator.minimise()
        coordinator.start(mode: .video)

        XCTAssertTrue(coordinator.isPresenting)
        XCTAssertIdentical(
            coordinator.flow, first,
            "Starting while a call runs must re-enter it, never stack a second"
        )
        XCTAssertEqual(coordinator.flow?.mode, .voice, "The original call's mode wins")
    }

    func testMinimiseHidesTheCoverButKeepsTheCallRunning() async {
        let coordinator = makeCoordinator()
        coordinator.start(mode: .voice)
        // Let matchmaking finish (mock search + connect ≈ 2.3s).
        await settle(3000)

        XCTAssertTrue(coordinator.hasActiveCall, "The call should be live by now")

        coordinator.minimise()

        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertTrue(coordinator.hasMinimisedCall)
        XCTAssertNotNil(coordinator.flow, "Minimising must not end the call")

        coordinator.resume()
        XCTAssertTrue(coordinator.isPresenting)
    }

    func testCallEndingWhileMinimisedRepresentsTheDecisionScreen() async {
        let coordinator = makeCoordinator()
        coordinator.start(mode: .voice)
        await settle(3000)
        XCTAssertTrue(coordinator.hasActiveCall, "The call should be live by now")

        coordinator.minimise()
        XCTAssertFalse(coordinator.isPresenting)

        // The call ends behind the tabs (timer, peer hang-up, End Call from a
        // re-entered moment — all land on .deciding).
        coordinator.flow?.endCall()
        await settle(100)

        guard case .deciding = coordinator.flow?.stage else {
            return XCTFail("Expected the decision stage, got \(String(describing: coordinator.flow?.stage))")
        }
        XCTAssertTrue(
            coordinator.isPresenting,
            "A minimised call that ended must re-present — the like/pass decision may never be stranded"
        )
    }

    func testFinishingTheFlowTearsItDown() async {
        let coordinator = makeCoordinator()
        coordinator.start(mode: .voice)

        coordinator.flow?.cancel()
        await settle(50)

        XCTAssertNil(coordinator.flow, "A cancelled search leaves no flow behind")
        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertFalse(coordinator.hasActiveCall)
    }
}
