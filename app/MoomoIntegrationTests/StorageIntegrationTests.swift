import XCTest
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import Moomo

#if canImport(FirebaseAuth)
import FirebaseAuth
#endif
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif

/// Photo upload against the **real** `moomo-c7a37` Storage bucket.
///
/// The unit suite proves the pipeline's logic on a local service. It cannot
/// prove the bucket exists, that the rules admit the app's writes, or that the
/// `contentType` the SDK sends satisfies them — and all three were broken
/// before this phase. That is what these cover.
///
///     xcodebuild test -project Moomo.xcodeproj -scheme MoomoIntegration \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:MoomoIntegrationTests/StorageIntegrationTests
///
/// Each test signs in as a fresh anonymous user, uploads under its own uid, and
/// deletes what it wrote.
final class StorageIntegrationTests: XCTestCase {

    #if canImport(FirebaseStorage) && canImport(FirebaseAuth)
    private var service: FirebaseStorageService!
    private var uploadedPaths: [String] = []
    private var uid: String!

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(
            BackendConfiguration.current == .firebase(projectID: "moomo-c7a37"),
            "Live Storage tests need GoogleService-Info.plist for moomo-c7a37."
        )

        FirebaseBootstrap.configureIfNeeded()
        service = FirebaseStorageService()

        let result = try await Auth.auth().signInAnonymously()
        uid = result.user.uid
    }

    override func tearDown() async throws {
        for path in uploadedPaths {
            try? await service.delete(remotePath: path)
        }
        uploadedPaths = []

        if let current = Auth.auth().currentUser {
            try? await current.delete()
        }
        service = nil
        try await super.tearDown()
    }

    private func track(_ path: String) -> String {
        uploadedPaths.append(path)
        return path
    }

    private func makeJPEG(width: Int = 1200, height: Int = 900) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    // MARK: - The bucket exists and accepts our writes

    /// The headline test: real bytes reach the real bucket and read back.
    /// Before this phase the bucket did not exist and this could not pass.
    func testUploadAndReadBackFromTheRealBucket() async throws {
        let original = try makeJPEG()
        let compressed = try ImageCompressor.compress(original)
        let photoID = UUID().uuidString

        let path = track(try await service.upload(
            imageData: compressed, uid: uid, photoId: photoID
        ))

        XCTAssertEqual(path, "users/\(uid!)/photos/\(photoID).jpg")

        let readBack = try await service.data(at: path)
        XCTAssertEqual(readBack, compressed, "Bytes must survive the round trip intact.")
    }

    /// The rules require `image/jpeg`. The SDK does not infer it from raw
    /// `Data`, so a missing `contentType` fails the write server-side. This
    /// asserts the app sets it.
    func testUploadSetsTheContentTypeTheRulesRequire() async throws {
        let compressed = try ImageCompressor.compress(try makeJPEG())
        let path = track(try await service.upload(
            imageData: compressed, uid: uid, photoId: UUID().uuidString
        ))

        let metadata = try await Storage.storage().reference(withPath: path).getMetadata()
        XCTAssertEqual(metadata.contentType, "image/jpeg")
    }

    func testDeleteRemovesThePhotoFromTheRealBucket() async throws {
        let compressed = try ImageCompressor.compress(try makeJPEG())
        let path = try await service.upload(
            imageData: compressed, uid: uid, photoId: UUID().uuidString
        )

        try await service.delete(remotePath: path)

        do {
            _ = try await service.data(at: path)
            XCTFail("Expected the photo to be gone from the bucket.")
        } catch {
            XCTAssertEqual(error as? PhotoUploadError, .notFound)
        }
    }

    // MARK: - The rules actually deny what they should

    /// Writing under another user's uid must be rejected. If this ever passes,
    /// any user can overwrite anyone's photos.
    func testCannotUploadUnderAnotherUsersPath() async throws {
        let compressed = try ImageCompressor.compress(try makeJPEG())

        do {
            _ = try await service.upload(
                imageData: compressed,
                uid: "some-other-users-uid",
                photoId: UUID().uuidString
            )
            XCTFail("Storage rules must reject writing to another user's path.")
        } catch {
            XCTAssertEqual(error as? PhotoUploadError, .unauthorized)
        }
    }

    /// The rules reject non-JPEG content. Enforced server-side so a tampered
    /// client cannot store arbitrary payloads in the photo bucket.
    func testRulesRejectNonImageContent() async throws {
        let path = StoragePath.photo(uid: uid, photoId: UUID().uuidString)
        let metadata = StorageMetadata()
        metadata.contentType = "application/zip"

        do {
            _ = try await Storage.storage().reference(withPath: path)
                .putDataAsync(Data("definitely not a photo".utf8), metadata: metadata)
            uploadedPaths.append(path)
            XCTFail("Storage rules must reject non-JPEG content types.")
        } catch {
            // Rejected, as intended.
        }
    }

    /// The rules cap uploads at 5MB. Compression should keep us well under, but
    /// the cap is what stops a tampered client filling the bucket.
    func testRulesRejectOversizedUploads() async throws {
        // Incompressible noise, so it stays large after JPEG encoding.
        var oversized = Data(count: 6 * 1024 * 1024)
        oversized.withUnsafeMutableBytes { buffer in
            for i in stride(from: 0, to: buffer.count, by: 1) {
                buffer[i] = UInt8.random(in: 0...255)
            }
        }

        let path = StoragePath.photo(uid: uid, photoId: UUID().uuidString)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        do {
            _ = try await Storage.storage().reference(withPath: path)
                .putDataAsync(oversized, metadata: metadata)
            uploadedPaths.append(path)
            XCTFail("Storage rules must reject uploads at or above 5MB.")
        } catch {
            // Rejected, as intended.
        }
    }

    /// Paths outside `users/{uid}/photos/` are denied by the catch-all rule.
    func testRulesDenyWritesOutsideThePhotoTree() async throws {
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        do {
            _ = try await Storage.storage().reference(withPath: "anything/else.jpg")
                .putDataAsync(try makeJPEG(width: 10, height: 10), metadata: metadata)
            uploadedPaths.append("anything/else.jpg")
            XCTFail("The catch-all rule must deny writes outside the photo tree.")
        } catch {
            // Rejected, as intended.
        }
    }
    #endif
}
