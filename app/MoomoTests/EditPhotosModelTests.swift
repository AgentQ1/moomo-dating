import XCTest
@testable import Moomo

/// The photo editor's persistence contract: saves are sequenced (never
/// fire-and-forget), Storage bytes are deleted only AFTER the profile write
/// is confirmed, and the upload queue the view renders is the model's own —
/// stable across the parent re-inits that used to split them.
@MainActor
final class EditPhotosModelTests: XCTestCase {

    private final class RecordingPhotoService: PhotoUploadService, @unchecked Sendable {
        private let lock = NSLock()
        private var _deleted: [String] = []
        var deleted: [String] { lock.withLock { _deleted } }

        func upload(imageData: Data, uid: String, photoId: String) async throws -> String {
            "users/\(uid)/photos/\(photoId).jpg"
        }
        func data(at remotePath: String) async throws -> Data { Data() }
        func delete(remotePath: String) async throws {
            lock.withLock { _deleted.append(remotePath) }
        }
    }

    /// Records every persisted snapshot; scripted to succeed or fail.
    private final class PersistRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _saved: [[ProfilePhoto]] = []
        var saved: [[ProfilePhoto]] { lock.withLock { _saved } }
        var succeeds = true

        func persist(_ photos: [ProfilePhoto]) async -> Bool {
            lock.withLock { _saved.append(photos) }
            return succeeds
        }
    }

    private let photos = [
        ProfilePhoto(id: "a", remotePath: "users/u1/photos/a.jpg", order: 0),
        ProfilePhoto(id: "b", remotePath: "users/u1/photos/b.jpg", order: 1),
    ]

    private func makeModel(
        service: RecordingPhotoService = RecordingPhotoService(),
        recorder: PersistRecorder
    ) -> EditPhotosModel {
        EditPhotosModel(
            uid: "u1",
            photos: photos,
            photoService: service,
            persist: { await recorder.persist($0) }
        )
    }

    func testTheQueueIsTheModelsOwnAndStable() {
        let recorder = PersistRecorder()
        let model = makeModel(recorder: recorder)
        XCTAssertIdentical(model.queue, model.queue, "One queue for the editor's lifetime")
    }

    func testRemovePersistsBeforeDeletingBytes() async {
        let service = RecordingPhotoService()
        let recorder = PersistRecorder()
        let model = makeModel(service: service, recorder: recorder)

        model.removePhoto(id: "a")
        await model.waitForPendingSaves()
        // Let the byte-deletion task (chained on the save) run.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.saved.count, 1)
        XCTAssertEqual(recorder.saved[0].map(\.id), ["b"], "The removal was persisted")
        XCTAssertEqual(service.deleted, ["users/u1/photos/a.jpg"], "Bytes go only after the save")
        XCTAssertEqual(model.photos.map(\.order), [0], "Remaining photos are renumbered")
    }

    func testFailedPersistNeverDeletesBytes() async {
        let service = RecordingPhotoService()
        let recorder = PersistRecorder()
        recorder.succeeds = false
        let model = makeModel(service: service, recorder: recorder)

        model.removePhoto(id: "a")
        await model.waitForPendingSaves()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(
            service.deleted.isEmpty,
            "A save that never landed must keep the bytes: the live profile still points at them"
        )
    }

    func testReorderIsPersistedWithRenumberedOrders() async {
        let recorder = PersistRecorder()
        let model = makeModel(recorder: recorder)

        model.movePhotos(from: IndexSet(integer: 1), to: 0)
        await model.waitForPendingSaves()

        XCTAssertEqual(recorder.saved.last?.map(\.id), ["b", "a"])
        XCTAssertEqual(recorder.saved.last?.map(\.order), [0, 1])
    }

    func testSavesAreSequencedInEditOrder() async {
        let recorder = PersistRecorder()
        let model = makeModel(recorder: recorder)

        // Two quick edits: the snapshots must persist in the order they were
        // made — the old fire-and-forget path let them race.
        model.movePhotos(from: IndexSet(integer: 1), to: 0)
        model.removePhoto(id: "b")
        await model.waitForPendingSaves()

        XCTAssertEqual(recorder.saved.count, 2)
        XCTAssertEqual(recorder.saved[0].map(\.id), ["b", "a"])
        XCTAssertEqual(recorder.saved[1].map(\.id), ["a"], "The later edit persists last")
    }
}
