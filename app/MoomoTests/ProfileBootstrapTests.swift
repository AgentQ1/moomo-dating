import XCTest
@testable import Moomo

/// Bootstrap idempotency and the "never overwrite real answers with provider
/// data" rule, exercised through the `ProfileStore` protocol.
///
/// These use an in-memory store that reproduces the contract
/// `FirestoreProfileStore` implements. They verify the *rules* — idempotency,
/// name precedence, consent refresh, uid stability — not Firestore itself.
/// Firestore's own transaction semantics are covered only against the emulator
/// or a live project, which this suite does not reach.
@MainActor
final class ProfileBootstrapTests: XCTestCase {

    private var store: InMemoryProfileStore!

    override func setUp() async throws {
        try await super.setUp()
        store = InMemoryProfileStore()
    }

    // MARK: - Idempotency

    /// The auth listener fires on every launch and every token refresh, so this
    /// runs constantly. It must never duplicate or reset.
    func testBootstrapTwiceCreatesOneDocument() async throws {
        _ = try await store.bootstrap(uid: "u1", provider: .guest, providerDisplayName: nil, consent: .now())
        _ = try await store.bootstrap(uid: "u1", provider: .guest, providerDisplayName: nil, consent: .now())

        XCTAssertEqual(store.documentCount, 1, "Repeated bootstrap must not duplicate documents")
    }

    func testBootstrapPreservesCreatedAt() async throws {
        let first = try await store.bootstrap(uid: "u1", provider: .guest, providerDisplayName: nil, consent: .now())
        try await Task.sleep(for: .milliseconds(20))
        let second = try await store.bootstrap(uid: "u1", provider: .guest, providerDisplayName: nil, consent: .now())

        XCTAssertEqual(first.createdAt, second.createdAt, "createdAt is immutable")
    }

    /// The regression that would hurt most: signing in again wiping a finished
    /// profile back to blank.
    func testBootstrapDoesNotResetCompletedProfile() async throws {
        _ = try await store.bootstrap(uid: "u1", provider: .apple, providerDisplayName: "Sam", consent: .now())
        _ = try await store.update(uid: "u1", profile: .completeFullProfile)
        _ = try await store.markOnboardingComplete(uid: "u1")

        let after = try await store.bootstrap(uid: "u1", provider: .apple, providerDisplayName: nil, consent: nil)

        XCTAssertNotNil(after.onboardingCompletedAt, "Onboarding completion must survive re-bootstrap")
        XCTAssertEqual(after.profile.displayName, Profile.completeFullProfile.displayName)
        XCTAssertEqual(after.profile.bio, Profile.completeFullProfile.bio)
    }

    // MARK: - Display name precedence

    func testProviderNameFillsBlankOnly() async throws {
        _ = try await store.bootstrap(uid: "u1", provider: .apple, providerDisplayName: "Apple Name", consent: .now())
        var chosen = Profile()
        chosen.displayName = "Chosen Name"
        _ = try await store.update(uid: "u1", profile: chosen)

        // Apple re-sends a name on a later sign-in; the user's choice must win.
        let after = try await store.bootstrap(uid: "u1", provider: .apple, providerDisplayName: "Apple Name", consent: nil)

        XCTAssertEqual(after.profile.displayName, "Chosen Name", "Provider data must not overwrite a chosen name")
    }

    /// Apple returns the name exactly once. If the first write missed it, a
    /// later bootstrap is the last chance to recover it.
    func testProviderNameBackfillsWhenStillBlank() async throws {
        _ = try await store.bootstrap(uid: "u1", provider: .apple, providerDisplayName: nil, consent: .now())
        let after = try await store.bootstrap(uid: "u1", provider: .apple, providerDisplayName: "Recovered", consent: nil)

        XCTAssertEqual(after.profile.displayName, "Recovered")
    }

    // MARK: - Consent

    func testConsentRecordedOnCreate() async throws {
        let user = try await store.bootstrap(uid: "u1", provider: .guest, providerDisplayName: nil, consent: .now())
        XCTAssertEqual(user.consent?.documentVersion, ConsentRecord.currentVersion)
    }

    /// Plain session restoration passes no consent and must not disturb it.
    func testNilConsentDoesNotClearStoredConsent() async throws {
        _ = try await store.bootstrap(uid: "u1", provider: .guest, providerDisplayName: nil, consent: .now())
        let after = try await store.bootstrap(uid: "u1", provider: .guest, providerDisplayName: nil, consent: nil)

        XCTAssertNotNil(after.consent, "Restoration must not clear consent")
    }

    func testStaleConsentIsRefreshed() async throws {
        let old = ConsentRecord(acceptedAt: Date(timeIntervalSince1970: 0), documentVersion: "1999-01-01")
        _ = try await store.bootstrap(uid: "u1", provider: .guest, providerDisplayName: nil, consent: old)

        let after = try await store.bootstrap(uid: "u1", provider: .guest, providerDisplayName: nil, consent: .now())

        XCTAssertEqual(after.consent?.documentVersion, ConsentRecord.currentVersion)
    }

    // MARK: - Linking

    /// Linking must upgrade in place — same uid, one document, nothing lost.
    func testLinkingKeepsUidAndSingleDocument() async throws {
        _ = try await store.bootstrap(uid: "u1", provider: .guest, providerDisplayName: nil, consent: .now())
        _ = try await store.update(uid: "u1", profile: .completeGuestProfile)

        let linked = try await store.bootstrap(uid: "u1", provider: .apple, providerDisplayName: nil, consent: nil)

        XCTAssertEqual(linked.id, "u1")
        XCTAssertEqual(linked.authProvider, .apple, "Provider metadata must update")
        XCTAssertFalse(linked.isGuest)
        XCTAssertEqual(store.documentCount, 1, "Linking must not create a second document")
        XCTAssertEqual(linked.profile.displayName, Profile.completeGuestProfile.displayName)
    }

    // MARK: - Public projection

    /// The public projection must never carry date of birth or consent.
    func testPublicProjectionExcludesPrivateFields() async throws {
        _ = try await store.bootstrap(uid: "u1", provider: .apple, providerDisplayName: nil, consent: .now())
        _ = try await store.update(uid: "u1", profile: .completeFullProfile)

        let projection = try XCTUnwrap(store.publicProfiles["u1"])
        XCTAssertNil(projection["dateOfBirth"], "Date of birth must never reach publicProfiles")
        XCTAssertNil(projection["consent"], "Consent must never reach publicProfiles")
        XCTAssertNil(projection["latitude"])
        XCTAssertNil(projection["longitude"])
        XCTAssertNotNil(projection["displayName"])
    }
}

/// In-memory `ProfileStore` mirroring the Firestore contract.
final class InMemoryProfileStore: ProfileStore, @unchecked Sendable {
    private(set) var users: [String: User] = [:]
    private(set) var publicProfiles: [String: [String: Any]] = [:]

    var documentCount: Int { users.count }

    func bootstrap(
        uid: String,
        provider: AuthProvider,
        providerDisplayName: String?,
        consent: ConsentRecord?
    ) async throws -> User {
        if var existing = users[uid] {
            existing.authProvider = provider
            if existing.profile.displayName.isEmpty,
               let providerDisplayName, !providerDisplayName.isEmpty {
                existing.profile.displayName = providerDisplayName
            }
            if let consent, existing.consent?.documentVersion != consent.documentVersion {
                existing.consent = consent
            }
            users[uid] = existing
            return existing
        }

        var profile = Profile()
        profile.displayName = providerDisplayName ?? ""
        let user = User(
            id: uid,
            authProvider: provider,
            consent: consent,
            profile: profile,
            createdAt: Date(),
            onboardingCompletedAt: nil
        )
        users[uid] = user
        return user
    }

    func update(uid: String, profile: Profile) async throws -> User {
        guard var user = users[uid] else { throw AuthError.unknown("Not found") }
        user.profile = profile
        users[uid] = user

        var projection: [String: Any] = ["uid": uid, "displayName": profile.displayName]
        if let age = profile.age { projection["age"] = age }
        if let city = profile.location?.city { projection["city"] = city }
        publicProfiles[uid] = projection

        return user
    }

    func markOnboardingComplete(uid: String) async throws -> User {
        guard var user = users[uid] else { throw AuthError.unknown("Not found") }
        user.onboardingCompletedAt = Date()
        users[uid] = user
        return user
    }
}
