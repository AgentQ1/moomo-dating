import XCTest
@testable import Moomo

/// The call countdown's wall-clock honesty and the idle-timer contract.
@MainActor
final class CallClockAndIdleTests: XCTestCase {

    private let kenji = DiscoveryCandidate(
        id: "u-featured", displayName: "Kenji", age: 26, city: "Chicago",
        photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .he
    )

    private func settle(_ ms: UInt64 = 150) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    // MARK: - Countdown

    func testRemainingTimeIsRecomputedFromTheSessionStart() {
        let start = Date()
        let session = CallSession(
            id: "s", candidate: kenji, mode: .voice,
            startedAt: start, maxDuration: 180
        )

        XCTAssertEqual(CallFlowModel.remainingSeconds(in: session, now: start), 180)
        // A minute of wall clock elapses — however many ticks actually fired,
        // the countdown must say 120, not "180 minus ticks delivered".
        XCTAssertEqual(
            CallFlowModel.remainingSeconds(in: session, now: start.addingTimeInterval(60)), 120
        )
        XCTAssertEqual(
            CallFlowModel.remainingSeconds(in: session, now: start.addingTimeInterval(300)), 0,
            "Past the end it clamps to zero, never negative"
        )
    }

    // MARK: - Idle timer

    private func startedFlow(
        idleChanges: @escaping @Sendable (Bool) -> Void,
        callDuration: TimeInterval = CallSession.speedCallDuration
    ) async -> CallFlowModel {
        let flow = CallFlowModel(
            mode: .voice,
            preferred: kenji,
            calls: MockCallService(
                searchLatency: .milliseconds(1),
                connectLatency: .milliseconds(1)
            ),
            matches: MockMatchService(latency: .milliseconds(1)),
            safety: MockSafetyService(),
            media: MockCallMediaService(),
            permissions: StubCallPermissions(),
            callDuration: callDuration,
            setIdleTimerDisabled: idleChanges,
            onFinished: {}
        )
        flow.start()
        await settle(200)
        return flow
    }

    func testIdleTimerIsDisabledForTheCallAndRestoredAfter() async {
        let recorder = IdleRecorder()
        let flow = await startedFlow(idleChanges: { recorder.append($0) })

        guard case .active = flow.stage else {
            return XCTFail("Expected an active call, got \(flow.stage)")
        }
        XCTAssertEqual(recorder.values, [true], "The screen must not sleep mid-call")

        flow.endCall()
        await settle(50)
        XCTAssertEqual(recorder.values, [true, false], "Restored the moment the call ends")
    }

    func testIdleTimerIsRestoredWhenTheClockExpires() async {
        let recorder = IdleRecorder()
        let flow = await startedFlow(idleChanges: { recorder.append($0) }, callDuration: 0.2)

        // Expiry ends the call by itself.
        await settle(1500)

        guard case .deciding = flow.stage else {
            return XCTFail("Expected the decision screen, got \(flow.stage)")
        }
        XCTAssertEqual(recorder.values, [true, false])
    }

    private final class IdleRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Bool] = []
        var values: [Bool] { lock.withLock { _values } }
        func append(_ value: Bool) { lock.withLock { _values.append(value) } }
    }
}
