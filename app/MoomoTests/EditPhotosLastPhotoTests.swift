import XCTest
@testable import Moomo

/// Removing your only photo must not eject you from the app.
///
/// Regression, reported 2026-08-12: "when i try to change profile pic it sent
/// me on start with name". Changing a single-photo profile means tapping the
/// ✕ on the photo you have, and the editor persisted the emptied array
/// immediately. `ProfileRequirements.missingFields` counts an empty photo list
/// as a missing required field, so `hasValidProfileState` went false and
/// `SessionStore` re-derived `.onboarding` — dropping the user on
/// `OnboardingStep.name`, the default `currentStep` of a fresh draft, in the
/// middle of editing a photo.
///
/// The routing rule itself is correct and deliberate
/// (`AuthenticationTests.testCompletedOnboardingWithMissingFieldsRoutesToOnboarding`):
/// a profile that has lost a required field belongs in onboarding. The defect
/// was that the editor offered an action the app cannot honour. A photo is
/// required, so the last one is not removable — you replace it by adding
/// another first.
@MainActor
final class EditPhotosLastPhotoTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: MockUserStore!
    private var auth: MockAuthenticationService!
    private var session: SessionStore!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = MockUserStore(defaults: defaults)
        auth = MockAuthenticationService(latency: .milliseconds(1), store: store)
        session = SessionStore(auth: auth)
        await settle()
    }

    override func tearDown() async throws {
        store.reset()
        session = nil
        auth = nil
        store = nil
        defaults = nil
        try await super.tearDown()
    }

    private func settle(_ ms: UInt64 = 60) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    private final class StubPhotoService: PhotoUploadService, @unchecked Sendable {
        func upload(imageData: Data, uid: String, photoId: String) async throws -> String {
            "users/\(uid)/photos/\(photoId).jpg"
        }
        func data(at remotePath: String) async throws -> Data { Data() }
        func delete(remotePath: String) async throws {}
    }

    /// Signs in and lands on `.main` with a complete, single-photo profile —
    /// the shape every account that uploaded one photo has.
    private func signInWithOnePhoto() async {
        let model = PhoneAuthModel(auth: auth)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: true)
        await settle(150)
        model.code = MockAuthenticationService.validVerificationCode
        model.verifyCode()
        await settle(300)

        await session.updateProfile(.completeFullProfile)
        await session.completeOnboarding()
        await settle(200)

        XCTAssertEqual(session.route, .main, "precondition: onboarded user is in the app")
        XCTAssertEqual(session.user?.profile.photos.count, 1, "precondition: exactly one photo")
    }

    /// Mirrors `MoomoTabBar.profileDestination(.editPhotos)` exactly, so the
    /// test exercises the wiring the app actually ships.
    private func makeEditor() -> EditPhotosModel {
        EditPhotosModel(
            uid: session.user?.id ?? "",
            photos: session.user?.profile.photos ?? [],
            photoService: StubPhotoService(),
            persist: { [weak session] photos in
                guard let session, var profile = session.user?.profile else { return false }
                profile.photos = photos
                return await session.updateProfile(profile)
            }
        )
    }

    /// The reported bug, end to end.
    func testRemovingTheOnlyPhotoDoesNotBounceToOnboarding() async {
        await signInWithOnePhoto()
        let editor = makeEditor()
        let onlyPhoto = try! XCTUnwrap(editor.photos.first)

        editor.removePhoto(id: onlyPhoto.id)
        await editor.waitForPendingSaves()
        await settle(250)

        XCTAssertEqual(
            session.route, .main,
            "Editing a photo must never drop the user back into onboarding"
        )
        XCTAssertEqual(
            session.user?.profile.photos.count, 1,
            "The last photo must survive — a profile without one cannot enter the app"
        )
    }

    /// The model refuses at the source, so any other caller is safe too.
    func testModelRefusesToEmptyThePhotoList() async {
        await signInWithOnePhoto()
        let editor = makeEditor()

        XCTAssertFalse(editor.canRemovePhotos, "One photo is the minimum")
        editor.removePhoto(id: editor.photos[0].id)
        await editor.waitForPendingSaves()

        XCTAssertEqual(editor.photos.count, 1)
    }

    /// The guard must not break ordinary removal.
    func testRemovingOneOfTwoPhotosStillWorks() async {
        await signInWithOnePhoto()

        var profile = try! XCTUnwrap(session.user?.profile)
        profile.photos.append(
            ProfilePhoto(id: "p2", remotePath: StoragePath.photo(uid: "test-uid", photoId: "p2"), order: 1)
        )
        await session.updateProfile(profile)
        await settle(200)

        let editor = makeEditor()
        XCTAssertEqual(editor.photos.count, 2)
        XCTAssertTrue(editor.canRemovePhotos)

        editor.removePhoto(id: "p2")
        await editor.waitForPendingSaves()
        await settle(250)

        XCTAssertEqual(editor.photos.count, 1)
        XCTAssertEqual(session.route, .main)
        XCTAssertEqual(session.user?.profile.photos.count, 1)
    }
}
