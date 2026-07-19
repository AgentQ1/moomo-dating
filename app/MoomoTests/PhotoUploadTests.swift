import XCTest
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import Moomo

// MARK: - Helpers

/// A real JPEG of the given size. Tests compress and upload actual image bytes
/// rather than random `Data` — random bytes are not an image, and every code
/// path here would reject them for the wrong reason.
private func makeJPEG(width: Int, height: Int) throws -> Data {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
    let unwrapped = try XCTUnwrap(context)

    // Some actual variation, so JPEG has something to compress and the encoded
    // size responds to dimensions the way a real photo's would.
    for i in 0..<12 {
        unwrapped.setFillColor(
            red: Double(i) / 12.0, green: 0.4, blue: 0.8, alpha: 1
        )
        unwrapped.fill(CGRect(
            x: i * width / 12, y: 0, width: width / 12, height: height
        ))
    }

    let image = try XCTUnwrap(unwrapped.makeImage())
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
}

private func dimensions(of data: Data) throws -> (width: Int, height: Int) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try XCTUnwrap(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    return (
        try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
        try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
    )
}

/// Fails every upload, to exercise the failure and retry paths.
private struct FailingUploadService: PhotoUploadService {
    var error: PhotoUploadError = .offline
    /// Flips to succeeding after the first attempt, for retry tests.
    var succeedAfterFirstAttempt = false
    let attempts = Attempts()

    final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            _count += 1
            return _count
        }
    }

    func upload(imageData: Data, uid: String, photoId: String) async throws -> String {
        let attempt = attempts.increment()
        if succeedAfterFirstAttempt && attempt > 1 {
            return StoragePath.photo(uid: uid, photoId: photoId)
        }
        throw error
    }

    func data(at remotePath: String) async throws -> Data { throw error }
    func delete(remotePath: String) async throws { throw error }
}

/// Wraps the local service, delaying wide images — so a batch's first (large)
/// photo completes after its smaller batch-mates. This is the completion-order
/// inversion the queue's order reservation exists to survive.
private struct StaggeredUploadService: PhotoUploadService {
    let backing: LocalPhotoUploadService

    init(root: URL) {
        backing = LocalPhotoUploadService(root: root)
    }

    func upload(imageData: Data, uid: String, photoId: String) async throws -> String {
        if let size = try? dimensions(of: imageData), size.width > 500 {
            try await Task.sleep(for: .milliseconds(250))
        }
        return try await backing.upload(imageData: imageData, uid: uid, photoId: photoId)
    }

    func data(at remotePath: String) async throws -> Data {
        try await backing.data(at: remotePath)
    }

    func delete(remotePath: String) async throws {
        try await backing.delete(remotePath: remotePath)
    }
}

// MARK: - Compression

final class ImageCompressorTests: XCTestCase {

    func testDownsamplesOversizedPhotoToMaxDimension() throws {
        let original = try makeJPEG(width: 4032, height: 3024)

        let compressed = try ImageCompressor.compress(original)
        let size = try dimensions(of: compressed)

        XCTAssertEqual(size.width, ImageCompressor.maxDimension)
        // Aspect ratio preserved: 4032/3024 = 4:3, so 1080 wide is 810 tall.
        XCTAssertEqual(size.height, 810)
    }

    func testDownsamplesOnLongEdgeForPortraitPhotos() throws {
        let original = try makeJPEG(width: 3024, height: 4032)

        let compressed = try ImageCompressor.compress(original)
        let size = try dimensions(of: compressed)

        // The long edge is capped, not the width.
        XCTAssertEqual(size.height, ImageCompressor.maxDimension)
        XCTAssertEqual(size.width, 810)
    }

    func testCompressionActuallyReducesSize() throws {
        let original = try makeJPEG(width: 4032, height: 3024)

        let compressed = try ImageCompressor.compress(original)

        XCTAssertLessThan(
            compressed.count, original.count,
            "Compressing a 4032px photo must produce fewer bytes than the original."
        )
    }

    func testCompressedPhotoFitsUnderTheStorageRuleLimit() throws {
        let original = try makeJPEG(width: 6000, height: 4000)

        let compressed = try ImageCompressor.compress(original)

        // The rule in backend/storage.rules rejects >= 5MB. If compression can
        // ever exceed it, uploads fail server-side with a confusing error.
        XCTAssertLessThan(compressed.count, 5 * 1024 * 1024)
    }

    func testDoesNotUpscaleSmallPhotos() throws {
        let original = try makeJPEG(width: 400, height: 300)

        let compressed = try ImageCompressor.compress(original)
        let size = try dimensions(of: compressed)

        // Upscaling would add bytes and no detail.
        XCTAssertEqual(size.width, 400)
        XCTAssertEqual(size.height, 300)
    }

    func testRejectsDataThatIsNotAnImage() {
        let notAnImage = Data("this is not a photo".utf8)

        XCTAssertThrowsError(try ImageCompressor.compress(notAnImage)) { error in
            XCTAssertEqual(error as? ImageCompressor.Failure, .unreadableImage)
        }
    }

    func testRejectsEmptyData() {
        XCTAssertThrowsError(try ImageCompressor.compress(Data())) { error in
            XCTAssertEqual(error as? ImageCompressor.Failure, .unreadableImage)
        }
    }
}

// MARK: - Local upload service

final class LocalPhotoUploadServiceTests: XCTestCase {

    private var root: URL!
    private var service: LocalPhotoUploadService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        service = LocalPhotoUploadService(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testUploadedBytesReadBackIdentically() async throws {
        let data = try makeJPEG(width: 100, height: 100)

        let path = try await service.upload(imageData: data, uid: "u1", photoId: "p1")
        let readBack = try await service.data(at: path)

        XCTAssertEqual(readBack, data, "A stored photo must read back byte-identical.")
    }

    func testUploadReturnsThePathTheRulesExpect() async throws {
        let data = try makeJPEG(width: 60, height: 60)

        let path = try await service.upload(imageData: data, uid: "u1", photoId: "p1")

        XCTAssertEqual(path, "users/u1/photos/p1.jpg")
    }

    func testReadingAMissingPhotoThrowsNotFound() async {
        do {
            _ = try await service.data(at: "users/u1/photos/nope.jpg")
            XCTFail("Expected a notFound error.")
        } catch {
            XCTAssertEqual(error as? PhotoUploadError, .notFound)
        }
    }

    func testDeleteRemovesTheBytes() async throws {
        let data = try makeJPEG(width: 60, height: 60)
        let path = try await service.upload(imageData: data, uid: "u1", photoId: "p1")

        try await service.delete(remotePath: path)

        do {
            _ = try await service.data(at: path)
            XCTFail("Expected the photo to be gone.")
        } catch {
            XCTAssertEqual(error as? PhotoUploadError, .notFound)
        }
    }

    func testDeletingAnAlreadyDeletedPhotoSucceeds() async throws {
        // Retried deletes must not surface an error — already-gone is the
        // desired end state.
        try await service.delete(remotePath: "users/u1/photos/never-existed.jpg")
    }
}

// MARK: - Upload queue

@MainActor
final class PhotoUploadQueueTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeQueue(
        service: PhotoUploadService? = nil,
        uploaded: @escaping (ProfilePhoto) -> Void
    ) -> PhotoUploadQueue {
        var photos: [ProfilePhoto] = []
        return PhotoUploadQueue(
            uid: "u1",
            service: service ?? LocalPhotoUploadService(root: root),
            currentPhotoCount: { photos.count },
            onUploaded: { photo in
                photos.append(photo)
                uploaded(photo)
            }
        )
    }

    func testSuccessfulUploadProducesAPhotoWithARealPath() async throws {
        var received: [ProfilePhoto] = []
        let queue = makeQueue { received.append($0) }
        let image = try makeJPEG(width: 800, height: 600)

        await queue.add([image])

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.remotePath, "users/u1/photos/\(received[0].id).jpg")
        XCTAssertTrue(queue.items.isEmpty, "A settled upload must leave the queue.")
    }

    func testUploadedBytesAreTheCompressedOnesNotTheOriginal() async throws {
        var received: [ProfilePhoto] = []
        let service = LocalPhotoUploadService(root: root)
        let queue = makeQueue(service: service) { received.append($0) }
        let original = try makeJPEG(width: 4032, height: 3024)

        await queue.add([original])

        let path = try XCTUnwrap(received.first?.remotePath)
        let stored = try await service.data(at: path)
        let size = try dimensions(of: stored)
        XCTAssertEqual(size.width, ImageCompressor.maxDimension,
                       "The queue must upload downsampled bytes, not the original.")
    }

    func testFailedUploadNeverProducesAPhoto() async throws {
        var received: [ProfilePhoto] = []
        let queue = makeQueue(service: FailingUploadService()) { received.append($0) }
        let image = try makeJPEG(width: 400, height: 400)

        await queue.add([image])

        // The invariant: a failed upload must not reach the profile.
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(queue.items.first?.failure, .offline)
        XCTAssertTrue(queue.hasFailures)
    }

    func testRetryAfterFailureProducesThePhoto() async throws {
        var received: [ProfilePhoto] = []
        let service = FailingUploadService(succeedAfterFirstAttempt: true)
        let queue = makeQueue(service: service) { received.append($0) }
        let image = try makeJPEG(width: 400, height: 400)

        await queue.add([image])
        XCTAssertTrue(received.isEmpty, "First attempt should fail.")

        let failedID = try XCTUnwrap(queue.items.first?.id)
        queue.retry(failedID)

        // Retry runs in a Task; wait for it to settle.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(service.attempts.count, 2)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testUnreadableImageFailsWithoutAttemptingUpload() async {
        var received: [ProfilePhoto] = []
        let service = FailingUploadService()
        let queue = makeQueue(service: service) { received.append($0) }

        await queue.add([Data("not a photo".utf8)])

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertNotNil(queue.items.first?.failure)
        XCTAssertEqual(service.attempts.count, 0,
                       "A photo that can't be decoded must not be uploaded.")
    }

    func testDiscardRemovesAFailedUpload() async throws {
        let queue = makeQueue(service: FailingUploadService()) { _ in }
        await queue.add([try makeJPEG(width: 400, height: 400)])

        let id = try XCTUnwrap(queue.items.first?.id)
        queue.discard(id)

        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertFalse(queue.hasFailures)
    }

    func testMultiplePhotosGetSequentialOrder() async throws {
        var received: [ProfilePhoto] = []
        let queue = makeQueue { received.append($0) }

        await queue.add([try makeJPEG(width: 300, height: 300)])
        await queue.add([try makeJPEG(width: 300, height: 300)])
        await queue.add([try makeJPEG(width: 300, height: 300)])

        XCTAssertEqual(received.map(\.order), [0, 1, 2])
    }

    func testConcurrentBatchKeepsSelectionOrderEvenWhenTheFirstUploadIsSlowest() async throws {
        var received: [ProfilePhoto] = []
        let service = StaggeredUploadService(root: root)
        let queue = makeQueue(service: service) { received.append($0) }

        // First selected photo is large, so it uploads slowest; order must
        // come from selection, never from upload completion.
        let first = try makeJPEG(width: 2000, height: 2000)
        let second = try makeJPEG(width: 300, height: 300)

        await queue.add([first, second])

        XCTAssertEqual(received.count, 2)
        let sorted = received.sorted { $0.order < $1.order }
        XCTAssertEqual(sorted.map(\.order), [0, 1])

        // Order 0 must be the *first selected* photo — the big one.
        let primaryBytes = try await service.data(at: sorted[0].remotePath)
        let primarySize = try dimensions(of: primaryBytes)
        XCTAssertEqual(
            primarySize.width, ImageCompressor.maxDimension,
            "The first photo the user picked must stay primary, even when it uploads last."
        )
    }

    func testUploadPrimesTheImageCache() async throws {
        var received: [ProfilePhoto] = []
        let queue = makeQueue { received.append($0) }
        await PhotoImageCache.shared.clear()

        await queue.add([try makeJPEG(width: 500, height: 500)])

        let path = try XCTUnwrap(received.first?.remotePath)
        let cached = await PhotoImageCache.shared.cached(path)
        XCTAssertNotNil(cached, "A just-uploaded photo must not need re-downloading.")
    }
}

// MARK: - The completion invariant

@MainActor
final class OnboardingPhotoGateTests: XCTestCase {

    private var root: URL!
    private var defaults: UserDefaults!
    private var storage: OnboardingDraftStorage!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        storage = OnboardingDraftStorage(defaults: defaults)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(
        service: PhotoUploadService? = nil
    ) -> OnboardingModel {
        let user = User(
            id: "u1",
            authProvider: .phone,
            consent: .now(),
            profile: Profile(),
            createdAt: Date(),
            onboardingCompletedAt: nil
        )
        return OnboardingModel(
            user: user,
            storage: storage,
            photoService: service ?? LocalPhotoUploadService(root: root)
        )
    }

    func testPhotosStepBlocksWithNoPhotos() {
        let model = makeModel()
        model.jumpToStepForTesting(.photos)

        XCTAssertEqual(model.validateCurrentStep(), "Please add at least one photo.")
    }

    func testPhotosStepPassesOnceAPhotoIsUploaded() async throws {
        let model = makeModel()
        model.jumpToStepForTesting(.photos)

        await model.photoQueue.add([try makeJPEG(width: 400, height: 400)])

        XCTAssertEqual(model.draft.profile.photos.count, 1)
        XCTAssertNil(model.validateCurrentStep())
    }

    func testPhotosStepStillBlocksWhenTheUploadFailed() async throws {
        let model = makeModel(service: FailingUploadService())
        model.jumpToStepForTesting(.photos)

        await model.photoQueue.add([try makeJPEG(width: 400, height: 400)])

        XCTAssertTrue(model.draft.profile.photos.isEmpty)
        XCTAssertEqual(
            model.validateCurrentStep(),
            "Your photo didn't upload. Retry it or pick another."
        )
    }

    func testCompletionIsBlockedWhenTheOnlyPhotoFailedToUpload() async throws {
        let model = makeModel(service: FailingUploadService())
        await model.photoQueue.add([try makeJPEG(width: 400, height: 400)])

        XCTAssertNotNil(
            model.uploadGateFailure(),
            "Onboarding must not complete when no photo actually uploaded."
        )
    }

    func testCompletionIsAllowedOnceAPhotoIsUploaded() async throws {
        let model = makeModel()
        await model.photoQueue.add([try makeJPEG(width: 400, height: 400)])

        XCTAssertNil(model.uploadGateFailure())
    }

    func testRemovingAPhotoRenumbersTheRest() async throws {
        let model = makeModel()
        for _ in 0..<3 {
            await model.photoQueue.add([try makeJPEG(width: 300, height: 300)])
        }
        let firstID = model.draft.profile.photos[0].id

        model.removePhoto(id: firstID)

        XCTAssertEqual(model.draft.profile.photos.count, 2)
        XCTAssertEqual(model.draft.profile.photos.map(\.order), [0, 1],
                       "Order must stay contiguous, or the primary photo changes on reload.")
    }

    func testReorderingMakesTheMovedPhotoPrimary() async throws {
        let model = makeModel()
        for _ in 0..<3 {
            await model.photoQueue.add([try makeJPEG(width: 300, height: 300)])
        }
        let originalSecond = model.draft.profile.photos[1].id

        model.movePhotos(from: IndexSet(integer: 1), to: 0)

        XCTAssertEqual(model.draft.profile.photos[0].id, originalSecond)
        XCTAssertEqual(model.draft.profile.photos[0].order, 0)
        XCTAssertEqual(model.draft.profile.photos.map(\.order), [0, 1, 2])
    }

    func testUploadedPhotosSurviveARelaunchMidFlow() async throws {
        let model = makeModel()
        model.jumpToStepForTesting(.photos)
        await model.photoQueue.add([try makeJPEG(width: 400, height: 400)])
        let path = model.draft.profile.photos[0].remotePath

        // A fresh model over the same storage is what a relaunch produces.
        let resumed = makeModel()

        XCTAssertEqual(resumed.draft.profile.photos.count, 1)
        XCTAssertEqual(resumed.draft.profile.photos[0].remotePath, path)
    }

    func testFailedUploadsAreNotPersistedAcrossRelaunch() async throws {
        let model = makeModel(service: FailingUploadService())
        model.jumpToStepForTesting(.photos)
        await model.photoQueue.add([try makeJPEG(width: 400, height: 400)])

        let resumed = makeModel()

        // The draft must not resurrect a photo that never uploaded — that was
        // the original bug, in its most durable form.
        XCTAssertTrue(resumed.draft.profile.photos.isEmpty)
    }
}
