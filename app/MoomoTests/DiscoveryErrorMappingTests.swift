import XCTest
@testable import Moomo

#if canImport(FirebaseFunctions)
import FirebaseFunctions
#endif
#if canImport(FirebaseFirestore)
import FirebaseFirestore
#endif

/// The offline-card regression: Discover once renamed EVERY unknown failure
/// "You're offline" — an App Check rejection sent users debugging their
/// Wi-Fi. These tests pin the rule: only real connectivity loss and backend
/// `unavailable` may ever classify as offline; everything else keeps its
/// identity (and its diagnostic code).
final class DiscoveryErrorMappingTests: XCTestCase {

    private let functionsDomain = DiscoveryErrorClassifier.functionsErrorDomain
    private let firestoreDomain = DiscoveryErrorClassifier.firestoreErrorDomain

    // MARK: - What IS offline

    func testBackendUnavailableIsOffline() {
        XCTAssertEqual(
            DiscoveryErrorClassifier.classify(domain: functionsDomain, code: 14),
            .offline,
            "unavailable = outage or kill switch — the one Firebase code that may say offline"
        )
        XCTAssertEqual(
            DiscoveryErrorClassifier.classify(domain: firestoreDomain, code: 14),
            .offline
        )
    }

    func testGenuineConnectivityLossIsOffline() {
        for code in [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
        ] {
            XCTAssertEqual(
                DiscoveryErrorClassifier.classify(domain: NSURLErrorDomain, code: code),
                .offline,
                "URL error \(code) is real connectivity loss"
            )
        }
    }

    // MARK: - What is NOT offline (the regression)

    func testAppCheckRejectionIsNotOffline() {
        // The deploy-order landmine: enforceAppCheck live server-side while
        // the app's token isn't registered → every callable answers
        // unauthenticated. That is a configuration fault, never a Wi-Fi one.
        XCTAssertEqual(
            DiscoveryErrorClassifier.classify(domain: functionsDomain, code: 16),
            .loadFailed(code: "unauthenticated")
        )
    }

    func testRulesDenialIsNotOffline() {
        XCTAssertEqual(
            DiscoveryErrorClassifier.classify(domain: firestoreDomain, code: 7),
            .loadFailed(code: "permission-denied")
        )
    }

    func testMissingBackendFunctionIsNotOffline() {
        XCTAssertEqual(
            DiscoveryErrorClassifier.classify(domain: functionsDomain, code: 5),
            .loadFailed(code: "not-found"),
            "an undeployed getDiscoveryFeed must name itself, not blame the network"
        )
    }

    func testRateLimitGetsItsOwnHonestState() {
        XCTAssertEqual(
            DiscoveryErrorClassifier.classify(domain: functionsDomain, code: 8),
            .rateLimited
        )
    }

    func testKillSwitchAdjacentCodesStayDiagnosable() {
        XCTAssertEqual(
            DiscoveryErrorClassifier.classify(domain: functionsDomain, code: 9),
            .loadFailed(code: "failed-precondition")
        )
        XCTAssertEqual(
            DiscoveryErrorClassifier.classify(domain: functionsDomain, code: 4),
            .loadFailed(code: "deadline-exceeded"),
            "a slow server is not the user's connection"
        )
    }

    func testCancelledURLRequestIsNotOffline() {
        XCTAssertEqual(
            DiscoveryErrorClassifier.classify(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
            .loadFailed(code: "url-\(NSURLErrorCancelled)")
        )
    }

    func testUnknownDomainsNeverMasqueradeAsOffline() {
        let classified = DiscoveryErrorClassifier.classify(
            domain: "com.example.mystery", code: 42
        )
        XCTAssertEqual(classified, .loadFailed(code: "com.example.mystery#42"))
    }

    func testExistingDiscoveryErrorsPassThroughUnchanged() {
        XCTAssertEqual(DiscoveryErrorClassifier.classify(DiscoveryError.noUsersAvailable), .noUsersAvailable)
        XCTAssertEqual(DiscoveryErrorClassifier.classify(DiscoveryError.offline), .offline)
        XCTAssertEqual(DiscoveryErrorClassifier.classify(DiscoveryError.sessionExpired), .sessionExpired)
    }

    // MARK: - Refining the bare 401 (the 2026-07-22 incident)

    // The backend's `unauthenticated` is ambiguous by construction:
    // `enforceAppCheck` and `requireAuth` share the code. This table is the
    // single place that names the actual cause from the two client-side facts.

    func testNoSessionRefinesToSessionExpired() {
        XCTAssertEqual(
            DiscoveryErrorClassifier.refineUnauthenticated(hasSession: false, appCheckProblem: nil),
            .sessionExpired
        )
        XCTAssertEqual(
            DiscoveryErrorClassifier.refineUnauthenticated(
                hasSession: false, appCheckProblem: "token mint failed"
            ),
            .sessionExpired,
            "no session outranks App Check: without an ID token the 401 is guaranteed regardless"
        )
    }

    func testAppCheckProblemRefinesToANamedAppCheckDiagnostic() {
        XCTAssertEqual(
            DiscoveryErrorClassifier.refineUnauthenticated(
                hasSession: true, appCheckProblem: "debug token not registered"
            ),
            .loadFailed(code: "unauthenticated — App Check: debug token not registered"),
            "an enforcing backend refusing an unattested install must say so, not shrug"
        )
    }

    func testHealthyCredentialsKeepTheBareCode() {
        XCTAssertEqual(
            DiscoveryErrorClassifier.refineUnauthenticated(hasSession: true, appCheckProblem: nil),
            .loadFailed(code: "unauthenticated"),
            "when the client can't see the cause it must not invent one"
        )
    }

    func testOnlyTheBareUnauthenticatedTriggersTheRefinementPass() {
        XCTAssertTrue(DiscoveryError.loadFailed(code: "unauthenticated").isBareUnauthenticated)
        XCTAssertFalse(
            DiscoveryError.loadFailed(code: "unauthenticated — App Check: x").isBareUnauthenticated,
            "a refined code re-entering the pass would retry forever"
        )
        XCTAssertFalse(DiscoveryError.loadFailed(code: "permission-denied").isBareUnauthenticated)
        XCTAssertFalse(DiscoveryError.offline.isBareUnauthenticated)
        XCTAssertFalse(DiscoveryError.sessionExpired.isBareUnauthenticated)
    }

    func testSessionExpiredSpeaksOfSigningInNotConnectivity() {
        let copy = DiscoveryError.sessionExpired.errorDescription ?? ""
        XCTAssertTrue(copy.contains("session"), "the state must name the session, got: \(copy)")
        XCTAssertTrue(copy.contains("sign in"), "the fix is signing in, got: \(copy)")
        XCTAssertFalse(copy.lowercased().contains("offline"))
        XCTAssertFalse(copy.lowercased().contains("connection"))
    }

    // MARK: - The classifier's constants must track the Firebase SDK

    #if canImport(FirebaseFunctions) && canImport(FirebaseFirestore)
    func testPinnedDomainsAndCodesMatchTheSDK() {
        XCTAssertEqual(DiscoveryErrorClassifier.functionsErrorDomain, FunctionsErrorDomain)
        XCTAssertEqual(DiscoveryErrorClassifier.firestoreErrorDomain, FirestoreErrorDomain)
        XCTAssertEqual(FunctionsErrorCode.unavailable.rawValue, 14)
        XCTAssertEqual(FunctionsErrorCode.resourceExhausted.rawValue, 8)
        XCTAssertEqual(FunctionsErrorCode.unauthenticated.rawValue, 16)
        XCTAssertEqual(FunctionsErrorCode.permissionDenied.rawValue, 7)
        XCTAssertEqual(FunctionsErrorCode.notFound.rawValue, 5)
    }
    #endif

    // MARK: - DiscoverModel no longer collapses unknowns into offline

    private struct FailingDiscoveryService: DiscoveryService {
        let error: Error
        func loadDiscovery() async throws -> DiscoveryState { throw error }
    }

    @MainActor
    func testModelClassifiesAppCheckRejectionInsteadOfClaimingOffline() async {
        let model = DiscoverModel(
            service: FailingDiscoveryService(
                error: NSError(domain: functionsDomain, code: 16)
            )
        )
        await model.load()
        XCTAssertEqual(model.phase, .failed(.loadFailed(code: "unauthenticated")))
    }

    @MainActor
    func testModelStillShowsOfflineForRealConnectivityLoss() async {
        let model = DiscoverModel(
            service: FailingDiscoveryService(
                error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            )
        )
        await model.load()
        XCTAssertEqual(model.phase, .failed(.offline))
    }

    @MainActor
    func testModelPreservesTypedDiscoveryErrors() async {
        let model = DiscoverModel(
            service: MockDiscoveryService(
                latency: .milliseconds(1),
                result: .failure(.noUsersAvailable)
            )
        )
        await model.load()
        XCTAssertEqual(model.phase, .failed(.noUsersAvailable))
    }
}
