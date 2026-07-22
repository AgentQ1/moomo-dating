import XCTest
@testable import Moomo

/// The seams the Firebase-backed services hang off. These run on test doubles
/// (unit tests never touch live Firebase), but they pin the contracts the
/// real backend relies on:
///  - a call record is keyed by the server session id, so ending a call and
///    stamping outcomes address the same `callSessions` document;
///  - a decision carries the session it came from, so the backend can verify
///    the caller was actually in that call;
///  - safety actions that fail to reach the backend say so, instead of
///    pretending someone was blocked or a report was filed.
@MainActor
final class RealBackendWiringTests: XCTestCase {

    private let kenji = DiscoveryCandidate(
        id: "u-featured", displayName: "Kenji", age: 26, city: "Chicago",
        photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .he
    )

    private var finishedCount = 0

    private func settle(_ ms: UInt64 = 100) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    // MARK: - Doubles

    /// Records the session id each decision arrives with.
    private final class CapturingMatchService: MatchService, @unchecked Sendable {
        private(set) var capturedSessionIDs: [String?] = []

        var matchesStream: AsyncStream<[Match]> { AsyncStream { $0.finish() } }
        func matches() async -> [Match] { [] }

        func submitDecision(
            _ decision: UserDecision,
            about candidate: DiscoveryCandidate,
            callSessionID: String?
        ) async throws -> DecisionOutcome {
            capturedSessionIDs.append(callSessionID)
            return decision == .like ? .likeSent : .passed
        }
    }

    /// A backend that is down: every block and report fails.
    private final class FailingSafetyService: SafetyService, @unchecked Sendable {
        struct Unreachable: Error {}

        var blockedUsersStream: AsyncStream<[BlockedUser]> { AsyncStream { $0.finish() } }
        func blockedUsers() async -> [BlockedUser] { [] }
        func isBlocked(_ userID: String) async -> Bool { false }
        func block(_ candidate: DiscoveryCandidate) async throws { throw Unreachable() }
        func unblock(_ userID: String) async {}
        @discardableResult
        func report(_ candidate: DiscoveryCandidate, reason: ReportReason, details: String?) async throws -> Report {
            throw Unreachable()
        }
        func reports() async -> [Report] { [] }
        func unmatch(_ candidate: DiscoveryCandidate, reason: UnmatchReason) async throws {
            throw Unreachable()
        }
    }

    private func startedFlow(
        matches: MatchService,
        safety: SafetyService,
        calls: MockCallService = MockCallService(
            searchLatency: .milliseconds(1),
            connectLatency: .milliseconds(1)
        )
    ) async -> (CallFlowModel, MockCallService) {
        let flow = CallFlowModel(
            mode: .voice,
            preferred: kenji,
            calls: calls,
            matches: matches,
            safety: safety,
            media: MockCallMediaService(),
            permissions: StubCallPermissions(),
            onFinished: { [weak self] in self?.finishedCount += 1 }
        )
        flow.start()
        await settle(150)
        return (flow, calls)
    }

    override func setUp() async throws {
        try await super.setUp()
        finishedCount = 0
    }

    // MARK: - Session-keyed records

    func testCallRecordIsKeyedByTheSessionID() async throws {
        let (flow, calls) = await startedFlow(
            matches: CapturingMatchService(),
            safety: MockSafetyService()
        )
        guard case .active(let session) = flow.stage else {
            return XCTFail("Expected an active call, got \(flow.stage)")
        }

        flow.endCall()
        await settle()

        let history = await calls.history()
        XCTAssertEqual(
            history.map(\.id), [session.id],
            "The record's id must be the session's id — it addresses the server-side callSessions document"
        )
        guard case .deciding(let summary) = flow.stage else {
            return XCTFail("Expected the decision screen, got \(flow.stage)")
        }
        XCTAssertEqual(summary.recordID, session.id)
    }

    func testDecisionCarriesTheCallSessionID() async throws {
        let matches = CapturingMatchService()
        let (flow, _) = await startedFlow(matches: matches, safety: MockSafetyService())
        guard case .active(let session) = flow.stage else {
            return XCTFail("Expected an active call, got \(flow.stage)")
        }
        flow.endCall()

        await flow.decide(.like)

        XCTAssertEqual(
            matches.capturedSessionIDs, [session.id],
            "The backend verifies decisions against the call they came from"
        )
    }

    // MARK: - Honest failure

    func testFailedBlockDoesNotFinishTheFlow() async throws {
        let (flow, calls) = await startedFlow(
            matches: CapturingMatchService(),
            safety: FailingSafetyService()
        )

        await flow.blockAndFinish()

        XCTAssertEqual(finishedCount, 0, "A block that never landed must not pretend it did")
        XCTAssertNotNil(flow.actionFailure)
        if case .active = flow.stage {} else {
            XCTFail("The call should still be running after a failed block")
        }
        let history = await calls.history()
        XCTAssertTrue(history.isEmpty, "No end-of-call record for a call that didn't end")
    }

    func testFailedReportIsNotConfirmed() async throws {
        let (flow, _) = await startedFlow(
            matches: CapturingMatchService(),
            safety: FailingSafetyService()
        )

        await flow.submitReport(reason: .harassment, details: nil)

        XCTAssertFalse(flow.didSubmitReport, "'Report received' may only follow a report that was received")
        XCTAssertNotNil(flow.actionFailure)
    }

    func testSuccessfulActionClearsTheFailure() async throws {
        let (flow, _) = await startedFlow(
            matches: CapturingMatchService(),
            safety: FailingSafetyService()
        )
        await flow.submitReport(reason: .spam, details: nil)
        XCTAssertNotNil(flow.actionFailure)

        // Same flow, working safety service: the stale failure must clear.
        let (recovered, _) = await startedFlow(
            matches: CapturingMatchService(),
            safety: MockSafetyService()
        )
        await recovered.submitReport(reason: .spam, details: nil)
        XCTAssertTrue(recovered.didSubmitReport)
        XCTAssertNil(recovered.actionFailure)
    }

    // MARK: - Composition root

    func testServiceFactoryUsesTheMockWorldUnderTests() {
        // Unit tests force the mock backend (BackendConfiguration refuses live
        // Firebase inside a hosted test process), so the factory must hand
        // back the in-memory graph — and it must be the wired one.
        XCTAssertTrue(BackendConfiguration.current.isMock)

        let user = User(
            id: "u-test",
            authProvider: .phone,
            consent: .now(),
            profile: Profile(),
            createdAt: Date(),
            onboardingCompletedAt: Date()
        )
        let services = AppServices.make(for: user)
        XCTAssertTrue(services.calls is MockCallService)
        XCTAssertTrue(services.matches is MockMatchService)
        XCTAssertTrue(services.discovery is BlockFilteringDiscoveryService)
        XCTAssertTrue(
            services.media is MockCallMediaService,
            "The mock world must never open real capture devices"
        )
        XCTAssertTrue(services.callPermissions is StubCallPermissions)
    }

    // MARK: - Firebase bootstrap ordering

    func testAppCheckFactoryInstallsBeforeFirebaseConfigures() {
        // `configureIfNeeded` routes its two steps through this seam. The
        // ordering is the whole point: a factory installed after
        // `FirebaseApp.configure()` loses the race for the first token
        // fetch, every callable then goes out unattested, and the enforcing
        // backend refuses the lot with a bare `unauthenticated`.
        var steps: [String] = []
        FirebaseBootstrap.runConfigurationSteps(
            installAppCheckFactory: { steps.append("app-check-factory") },
            configureFirebase: { steps.append("firebase-configure") }
        )
        XCTAssertEqual(steps, ["app-check-factory", "firebase-configure"])
    }
}
