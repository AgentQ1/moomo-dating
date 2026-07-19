import Foundation

#if canImport(FirebaseStorage)
import FirebaseStorage

/// Firebase Storage-backed photo storage.
struct FirebaseStorageService: PhotoUploadService {

    /// Matches the cap in `backend/storage.rules`. Enforced there too — this is
    /// the courteous check, not the load-bearing one.
    static let maxBytes = 5 * 1024 * 1024

    private var storage: Storage { Storage.storage() }

    func upload(imageData: Data, uid: String, photoId: String) async throws -> String {
        guard imageData.count < Self.maxBytes else { throw PhotoUploadError.tooLarge }

        let path = StoragePath.photo(uid: uid, photoId: photoId)
        let reference = storage.reference(withPath: path)

        let metadata = StorageMetadata()
        // Storage infers this wrongly for raw Data. Without it the rules'
        // contentType check rejects the write.
        metadata.contentType = "image/jpeg"

        do {
            _ = try await reference.putDataAsync(imageData, metadata: metadata)
        } catch {
            throw Self.map(error)
        }
        return path
    }

    func data(at remotePath: String) async throws -> Data {
        do {
            return try await storage.reference(withPath: remotePath)
                .data(maxSize: Int64(Self.maxBytes))
        } catch {
            throw Self.map(error)
        }
    }

    func delete(remotePath: String) async throws {
        do {
            try await storage.reference(withPath: remotePath).delete()
        } catch {
            let mapped = Self.map(error)
            // Already gone is the desired end state, not a failure. This happens
            // when a delete is retried after a response was lost.
            if mapped == .notFound { return }
            throw mapped
        }
    }

    /// Translates SDK errors into ones the UI can act on. Anything unmapped
    /// keeps its message rather than being flattened into "something went
    /// wrong" — a silent failure here is how photos vanish without explanation.
    private static func map(_ error: Error) -> PhotoUploadError {
        let nsError = error as NSError
        guard nsError.domain == StorageErrorDomain,
              let code = StorageErrorCode(rawValue: nsError.code) else {
            return .unknown(error.localizedDescription)
        }

        switch code {
        case .retryLimitExceeded:
            return .offline
        case .objectNotFound:
            return .notFound
        case .unauthorized, .unauthenticated:
            return .unauthorized
        case .quotaExceeded:
            return .tooLarge
        default:
            return .unknown(error.localizedDescription)
        }
    }
}
#endif
