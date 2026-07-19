import XCTest
@testable import Moomo

#if canImport(FirebaseAuth)
import FirebaseAuth
#endif

/// Integration tests against the **real** `moomo-c7a37` Firebase project.
///
/// Deliberately a separate target. The unit suite and the UI suite run on
/// injected mocks and must stay deterministic and offline; these do the
/// opposite on purpose — they exist to catch exactly the class of failure the
/// mocks cannot see, which is what the deny-all ruleset regression was.
///
/// # The harness identity
///
/// The app has no anonymous auth: production sign-in is phone verification
/// (or OAuth + a linked phone), and `FirebaseAuthenticationService` signs a
/// restored anonymous session out on sight. But live Firestore/Storage rules
/// still need *an authenticated uid* to test against, and an automated run
/// may not send real SMS or mint real OAuth identities against production.
/// So these tests mint a throwaway uid with the raw SDK's anonymous sign-in —
/// pure test scaffolding, exactly like `StorageIntegrationTests`, never
/// touching any app code path — and drive `FirestoreProfileStore` directly.
///
/// If Anonymous sign-in is ever disabled in the console, configure a Firebase
/// *test phone number* (Authentication → Sign-in method → Phone) and switch
/// `mintTestUID()` to the phone flow with that fixture.
///
/// Every test deletes its own auth user afterwards; document residue is
/// cleared by `backend/scripts/cleanup-integration-data.sh`.
///
///     xcodebuild test -project Moomo.xcodeproj -scheme Moomo \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:MoomoIntegrationTests
///
/// Skips rather than fails when the SDK or config is absent, so a checkout
/// without `GoogleService-Info.plist` does not report a false failure.
final class FirebaseIntegrationTests: XCTestCase {

    #if canImport(FirebaseAuth)
    private var createdUID: String?

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(
            BackendConfiguration.current == .firebase(projectID: "moomo-c7a37"),
            "Live integration tests need GoogleService-Info.plist for moomo-c7a37."
        )

        FirebaseBootstrap.configureIfNeeded()
    }

    override func tearDown() async throws {
        // Removes the auth account this test created. It does NOT remove the
        // account's Firestore documents — rules forbid client deletes of
        // users/{uid} by design; the cleanup script sweeps them.
        if let uid = createdUID {
            if let current = FirebaseAuth.Auth.auth().currentUser, current.uid == uid {
                try? await current.delete()
            }
            createdUID = nil
        }
        try await super.tearDown()
    }

    /// A fresh authenticated uid for this test. See the header — this is the
    /// harness, not an app path.
    private func mintTestUID() async throws -> String {
        let result = try await FirebaseAuth.Auth.auth().signInAnonymously()
        createdUID = result.user.uid
        return result.user.uid
    }

    // MARK: - The path that was broken

    /// Bootstrap → read back. This is the exact chain that returned
    /// PERMISSION_DENIED while the locked-mode ruleset was live, and the
    /// reason the UI suite sat on Welcome.
    func testBootstrapCreatesAndReadsBackUsersDocument() async throws {
        let uid = try await mintTestUID()

        let store = FirestoreProfileStore()
        let user = try await store.bootstrap(
            uid: uid, provider: .phone, providerDisplayName: nil, consent: .now()
        )

        XCTAssertEqual(user.id, uid)
        XCTAssertEqual(user.authProvider, .phone)
        XCTAssertNotNil(user.consent, "Consent must be recorded on first creation")

        // Read back, proving the document is really there and readable by its
        // owner — not just that the write returned.
        let readBack = try await store.bootstrap(
            uid: uid, provider: .phone, providerDisplayName: nil, consent: nil
        )
        XCTAssertEqual(readBack.id, uid, "Read-back must return the same uid")
        XCTAssertEqual(
            readBack.consent?.documentVersion, ConsentRecord.currentVersion,
            "Recorded consent must survive the round trip"
        )
    }

    /// Bootstrap runs on every launch and every token refresh. If it were not
    /// idempotent, a returning user would get a reset profile.
    func testBootstrapIsIdempotentAgainstRealFirestore() async throws {
        let uid = try await mintTestUID()

        let store = FirestoreProfileStore()
        let user = try await store.bootstrap(
            uid: uid, provider: .phone, providerDisplayName: nil, consent: .now()
        )

        var profile = Profile()
        profile.displayName = "Integration"
        profile.bio = "written by the integration suite"
        _ = try await store.update(uid: uid, profile: profile)

        // Bootstrap again, as a relaunch does.
        let again = try await store.bootstrap(
            uid: uid, provider: .phone, providerDisplayName: "Should Not Overwrite", consent: nil
        )

        XCTAssertEqual(again.id, uid, "uid must be stable")
        XCTAssertEqual(
            again.profile.displayName, "Integration",
            "Bootstrap must never overwrite a name the user has chosen"
        )
        XCTAssertEqual(again.createdAt.timeIntervalSince1970,
                       user.createdAt.timeIntervalSince1970,
                       accuracy: 1.0,
                       "createdAt must not be rewritten")
    }

    /// Onboarding data must survive the round trip through real Firestore.
    func testOnboardingDataIsWrittenAndRestored() async throws {
        let uid = try await mintTestUID()

        let store = FirestoreProfileStore()
        _ = try await store.bootstrap(
            uid: uid, provider: .phone, providerDisplayName: nil, consent: .now()
        )

        var profile = Profile()
        profile.displayName = "Riley"
        profile.bio = "hello from the integration suite"
        profile.interests = ["Hiking", "Coffee"]
        profile.dateOfBirth = Calendar.current.date(byAdding: .year, value: -30, to: Date())
        profile.gender = .woman
        profile.interestedIn = [.men]
        profile.location = CityLocation(city: "Chicago", region: "IL", countryCode: "US")
        profile.photos = [
            ProfilePhoto(id: "p1", remotePath: StoragePath.photo(uid: uid, photoId: "p1"), order: 0)
        ]

        _ = try await store.update(uid: uid, profile: profile)
        _ = try await store.markOnboardingComplete(uid: uid)

        let restored = try await store.bootstrap(
            uid: uid, provider: .phone, providerDisplayName: nil, consent: nil
        )

        XCTAssertEqual(restored.profile.displayName, "Riley")
        XCTAssertEqual(restored.profile.bio, "hello from the integration suite")
        XCTAssertEqual(restored.profile.interests, ["Hiking", "Coffee"])
        XCTAssertEqual(restored.profile.gender, .woman)
        XCTAssertNotNil(restored.onboardingCompletedAt, "Onboarding completion must persist")
        XCTAssertTrue(
            restored.hasValidProfileState,
            "A fully onboarded user must route to main, not back through onboarding"
        )
    }

    /// Photos must survive the round trip as real paths.
    ///
    /// This is the regression guard for the shape change in Phase 2. Firestore
    /// previously stored only `photoCount`, and the decoder rebuilt
    /// placeholders from that number — so a reload produced photos that pointed
    /// at nothing. Asserting the paths come back intact is what proves the
    /// profile now references bytes that actually exist.
    func testPhotoPathsSurviveTheFirestoreRoundTrip() async throws {
        let uid = try await mintTestUID()

        var profile = Profile()
        profile.displayName = "Riley"
        profile.photos = [
            ProfilePhoto(id: "a", remotePath: StoragePath.photo(uid: uid, photoId: "a"), order: 0),
            ProfilePhoto(id: "b", remotePath: StoragePath.photo(uid: uid, photoId: "b"), order: 1)
        ]

        let store = FirestoreProfileStore()
        _ = try await store.bootstrap(
            uid: uid, provider: .phone, providerDisplayName: nil, consent: .now()
        )
        _ = try await store.update(uid: uid, profile: profile)

        let restored = try await store.bootstrap(
            uid: uid, provider: .phone, providerDisplayName: nil, consent: nil
        )

        XCTAssertEqual(restored.profile.photos.count, 2)
        XCTAssertEqual(
            restored.profile.photos.map(\.remotePath),
            [
                StoragePath.photo(uid: uid, photoId: "a"),
                StoragePath.photo(uid: uid, photoId: "b")
            ],
            "Real storage paths must come back, not placeholders rebuilt from a count."
        )
        XCTAssertEqual(restored.profile.photos.map(\.order), [0, 1])
    }

    /// Photo order is what decides the primary photo. If Firestore returns them
    /// unordered, the user's main photo silently changes on every reload.
    func testPhotosComeBackInTheirSavedOrder() async throws {
        let uid = try await mintTestUID()

        var profile = Profile()
        profile.displayName = "Riley"
        // Written deliberately out of order.
        profile.photos = [
            ProfilePhoto(id: "third", remotePath: StoragePath.photo(uid: uid, photoId: "third"), order: 2),
            ProfilePhoto(id: "first", remotePath: StoragePath.photo(uid: uid, photoId: "first"), order: 0),
            ProfilePhoto(id: "second", remotePath: StoragePath.photo(uid: uid, photoId: "second"), order: 1)
        ]

        let store = FirestoreProfileStore()
        _ = try await store.bootstrap(
            uid: uid, provider: .phone, providerDisplayName: nil, consent: .now()
        )
        _ = try await store.update(uid: uid, profile: profile)
        let restored = try await store.bootstrap(
            uid: uid, provider: .phone, providerDisplayName: nil, consent: nil
        )

        XCTAssertEqual(restored.profile.photos.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(restored.profile.photos.first?.id, "first", "Order 0 is the primary photo.")
    }
    #else
    func testSkippedWithoutFirebaseSDK() throws {
        throw XCTSkip("Firebase SDK is not linked; live integration tests cannot run.")
    }
    #endif
}
