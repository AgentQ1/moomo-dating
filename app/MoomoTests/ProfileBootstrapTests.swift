import XCTest
@testable import Moomo

/// Bootstrap idempotency, exercised through the `ProfileStore` protocol.
///
/// These use an in-memory store that reproduces the contract
/// `FirestoreProfileStore` implements. They verify the *rules* — idempotency,
/// consent refresh, uid stability — not Firestore itself. Firestore's own
/// transaction semantics are covered only against the emulator or a live
/// project, which this suite does not reach.
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
        _ = try await store.bootstrap(uid: "u1", consent: .now())
        _ = try await store.bootstrap(uid: "u1", consent: .now())

        XCTAssertEqual(store.documentCount, 1, "Repeated bootstrap must not duplicate documents")
    }

    func testBootstrapPreservesCreatedAt() async throws {
        let first = try await store.bootstrap(uid: "u1", consent: .now())
        try await Task.sleep(for: .milliseconds(20))
        let second = try await store.bootstrap(uid: "u1", consent: .now())

        XCTAssertEqual(first.createdAt, second.createdAt, "createdAt is immutable")
    }

    /// The regression that would hurt most: signing in again wiping a finished
    /// profile back to blank.
    func testBootstrapDoesNotResetCompletedProfile() async throws {
        _ = try await store.bootstrap(uid: "u1", consent: .now())
        _ = try await store.update(uid: "u1", profile: .completeFullProfile)
        _ = try await store.markOnboardingComplete(uid: "u1")

        let after = try await store.bootstrap(uid: "u1", consent: nil)

        XCTAssertNotNil(after.onboardingCompletedAt, "Onboarding completion must survive re-bootstrap")
        XCTAssertEqual(after.profile.displayName, Profile.completeFullProfile.displayName)
        XCTAssertEqual(after.profile.bio, Profile.completeFullProfile.bio)
    }

    func testBootstrapKeepsUid() async throws {
        let user = try await store.bootstrap(uid: "u1", consent: .now())
        let again = try await store.bootstrap(uid: "u1", consent: nil)

        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(again.id, "u1")
    }

    // MARK: - Consent

    func testConsentRecordedOnCreate() async throws {
        let user = try await store.bootstrap(uid: "u1", consent: .now())
        XCTAssertEqual(user.consent?.documentVersion, ConsentRecord.currentVersion)
    }

    /// Plain session restoration passes no consent and must not disturb it.
    func testNilConsentDoesNotClearStoredConsent() async throws {
        _ = try await store.bootstrap(uid: "u1", consent: .now())
        let after = try await store.bootstrap(uid: "u1", consent: nil)

        XCTAssertNotNil(after.consent, "Restoration must not clear consent")
    }

    func testStaleConsentIsRefreshed() async throws {
        let old = ConsentRecord(acceptedAt: Date(timeIntervalSince1970: 0), documentVersion: "1999-01-01")
        _ = try await store.bootstrap(uid: "u1", consent: old)

        let after = try await store.bootstrap(uid: "u1", consent: .now())

        XCTAssertEqual(after.consent?.documentVersion, ConsentRecord.currentVersion)
    }

    // MARK: - Public projection

    /// The public projection must never carry date of birth or consent.
    func testPublicProjectionExcludesPrivateFields() async throws {
        _ = try await store.bootstrap(uid: "u1", consent: .now())
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

    func bootstrap(uid: String, consent: ConsentRecord?) async throws -> User {
        if var existing = users[uid] {
            if let consent, existing.consent?.documentVersion != consent.documentVersion {
                existing.consent = consent
            }
            users[uid] = existing
            return existing
        }

        let user = User(
            id: uid,
            authProvider: .phone,
            consent: consent,
            profile: Profile(),
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
