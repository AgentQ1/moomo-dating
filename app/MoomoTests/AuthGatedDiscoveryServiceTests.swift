import XCTest
@testable import Moomo

/// The auth gate in front of the real Discover feed (2026-07-22 incident:
/// the enforcing backend answered a bare `unauthenticated` and the card
/// couldn't say which credential was missing). These pin the gate's three
/// duties on doubles — no Firebase:
///  - the feed is NEVER called without a live session, and the failure is
///    `.sessionExpired`, not a load error;
///  - one 401 earns one retry, after a forced ID-token refresh;
///  - a 401 that survives the retry is refined into session-vs-App-Check,
///    and every other failure passes through with no retry at all.
final class AuthGatedDiscoveryServiceTests: XCTestCase {

    // MARK: - Doubles

    /// Scripted feed: pops one result per call, records how often it ran.
    private final class ScriptedFeed: DiscoveryService, @unchecked Sendable {
        private let lock = NSLock()
        private var script: [Result<DiscoveryState, DiscoveryError>]
        private var _callCount = 0

        init(_ script: [Result<DiscoveryState, DiscoveryError>]) {
            self.script = script
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _callCount
        }

        func loadDiscovery() async throws -> DiscoveryState {
            lock.lock(); defer { lock.unlock() }
            _callCount += 1
            guard !script.isEmpty else { return .empty }
            return try script.removeFirst().get()
        }
    }

    /// Counts how often the gate asked for an ID-token refresh.
    private final class RefreshRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        func record() {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }
    }

    /// Pops a scripted uid per `currentUID()` call, so a test can model the
    /// session dying between the first attempt and the retry.
    private final class SessionScript: @unchecked Sendable {
        private let lock = NSLock()
        private var uids: [String?]
        init(_ uids: [String?]) { self.uids = uids }
        func next() -> String? {
            lock.lock(); defer { lock.unlock() }
            guard !uids.isEmpty else { return nil }
            return uids.removeFirst()
        }
    }

    private let bareUnauthenticated = DiscoveryError.loadFailed(
        code: DiscoveryErrorClassifier.unauthenticatedCode
    )

    private func gate(
        feed: ScriptedFeed,
        uid: @escaping @Sendable () -> String? = { "u-1" },
        refresh: RefreshRecorder = RefreshRecorder(),
        refreshSucceeds: Bool = true,
        appCheckProblem: String? = nil
    ) -> AuthGatedDiscoveryService {
        AuthGatedDiscoveryService(
            base: feed,
            currentUID: uid,
            refreshSession: { refresh.record(); return refreshSucceeds },
            appCheckProblem: { appCheckProblem }
        )
    }

    // MARK: - Gate: no session, no call

    func testFeedIsNeverCalledBeforeAuthRestoreCompletes() async {
        let feed = ScriptedFeed([.success(.sample)])
        let service = gate(feed: feed, uid: { nil })

        do {
            _ = try await service.loadDiscovery()
            XCTFail("Expected sessionExpired")
        } catch let error as DiscoveryError {
            XCTAssertEqual(error, .sessionExpired)
        } catch {
            XCTFail("Expected DiscoveryError, got \(error)")
        }
        XCTAssertEqual(
            feed.callCount, 0,
            "getDiscoveryFeed must not fire without a restored Firebase session"
        )
    }

    // MARK: - Healthy path

    func testHealthyLoadPassesStraightThrough() async throws {
        let feed = ScriptedFeed([.success(.sample)])
        let refresh = RefreshRecorder()
        let service = gate(feed: feed, refresh: refresh)

        let state = try await service.loadDiscovery()

        XCTAssertEqual(state, .sample)
        XCTAssertEqual(feed.callCount, 1)
        XCTAssertEqual(refresh.count, 0, "no failure, no token churn")
    }

    // MARK: - One retry after refresh

    func testOneUnauthenticatedEarnsOneRetryAfterTokenRefresh() async throws {
        let feed = ScriptedFeed([.failure(bareUnauthenticated), .success(.sample)])
        let refresh = RefreshRecorder()
        let service = gate(feed: feed, refresh: refresh)

        let state = try await service.loadDiscovery()

        XCTAssertEqual(state, .sample, "a transiently stale token must recover invisibly")
        XCTAssertEqual(feed.callCount, 2)
        XCTAssertEqual(refresh.count, 1, "the retry flies on a force-refreshed ID token")
    }

    // MARK: - Refinement after a failed retry

    func testPersistentUnauthenticatedWithAppCheckProblemNamesAppCheck() async {
        let feed = ScriptedFeed([
            .failure(bareUnauthenticated), .failure(bareUnauthenticated),
        ])
        let service = gate(
            feed: feed,
            appCheckProblem: "debug token not registered"
        )

        do {
            _ = try await service.loadDiscovery()
            XCTFail("Expected refined loadFailed")
        } catch let error as DiscoveryError {
            XCTAssertEqual(
                error,
                .loadFailed(code: "unauthenticated — App Check: debug token not registered"),
                "an App Check refusal must name itself, never hide behind the bare 401"
            )
        } catch {
            XCTFail("Expected DiscoveryError, got \(error)")
        }
        XCTAssertEqual(feed.callCount, 2, "exactly one retry — never a hammer loop")
    }

    func testPersistentUnauthenticatedWithHealthyCredentialsKeepsBareCode() async {
        let feed = ScriptedFeed([
            .failure(bareUnauthenticated), .failure(bareUnauthenticated),
        ])
        let service = gate(feed: feed, appCheckProblem: nil)

        do {
            _ = try await service.loadDiscovery()
            XCTFail("Expected loadFailed")
        } catch let error as DiscoveryError {
            XCTAssertEqual(
                error, bareUnauthenticated,
                "with both credentials healthy the client must not invent a cause"
            )
        } catch {
            XCTFail("Expected DiscoveryError, got \(error)")
        }
    }

    func testSessionDyingMidLoadBecomesSessionExpiredWithoutARetry() async {
        let feed = ScriptedFeed([.failure(bareUnauthenticated)])
        let refresh = RefreshRecorder()
        let sessions = SessionScript(["u-1", nil])
        let service = gate(feed: feed, uid: { sessions.next() }, refresh: refresh)

        do {
            _ = try await service.loadDiscovery()
            XCTFail("Expected sessionExpired")
        } catch let error as DiscoveryError {
            XCTAssertEqual(error, .sessionExpired, "sign-out mid-flight is routing, not retrying")
        } catch {
            XCTFail("Expected DiscoveryError, got \(error)")
        }
        XCTAssertEqual(feed.callCount, 1)
        XCTAssertEqual(refresh.count, 0)
    }

    // MARK: - Everything else passes through untouched

    func testNonAuthFailuresPropagateWithoutRetry() async {
        for failure in [DiscoveryError.offline, .rateLimited, .loadFailed(code: "not-found")] {
            let feed = ScriptedFeed([.failure(failure)])
            let refresh = RefreshRecorder()
            let service = gate(feed: feed, refresh: refresh)

            do {
                _ = try await service.loadDiscovery()
                XCTFail("Expected \(failure)")
            } catch let error as DiscoveryError {
                XCTAssertEqual(error, failure)
            } catch {
                XCTFail("Expected DiscoveryError, got \(error)")
            }
            XCTAssertEqual(feed.callCount, 1, "\(failure) is not an auth problem — no retry")
            XCTAssertEqual(refresh.count, 0)
        }
    }

    func testAlreadyRefinedCodeDoesNotReenterTheRetryPass() async {
        let refined = DiscoveryError.loadFailed(code: "unauthenticated — App Check: x")
        let feed = ScriptedFeed([.failure(refined)])
        let refresh = RefreshRecorder()
        let service = gate(feed: feed, refresh: refresh)

        do {
            _ = try await service.loadDiscovery()
            XCTFail("Expected refined error")
        } catch let error as DiscoveryError {
            XCTAssertEqual(error, refined)
        } catch {
            XCTFail("Expected DiscoveryError, got \(error)")
        }
        XCTAssertEqual(feed.callCount, 1)
        XCTAssertEqual(refresh.count, 0, "only the BARE unauthenticated may trigger the pass")
    }
}
