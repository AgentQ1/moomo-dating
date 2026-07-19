import Foundation

/// Uploads profile photos and reads them back.
///
/// A protocol so the photo grid is testable without a live bucket, and so mock
/// mode uses the same shape. Both implementations do real work — neither
/// returns a fabricated success.
protocol PhotoUploadService: Sendable {
    /// Compresses nothing — callers pass already-compressed JPEG bytes.
    /// Returns the storage path to persist, e.g. `users/{uid}/photos/{id}.jpg`.
    func upload(imageData: Data, uid: String, photoId: String) async throws -> String

    /// Bytes for a stored path. Used to render previews and Discover photos.
    func data(at remotePath: String) async throws -> Data

    func delete(remotePath: String) async throws
}

enum PhotoUploadError: LocalizedError, Equatable {
    case offline
    case tooLarge
    case notFound
    case unauthorized
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .offline: "You're offline. Your photo will need re-adding when you reconnect."
        case .tooLarge: "That photo is too large, even after compressing."
        case .notFound: "That photo is no longer available."
        case .unauthorized: "You're not allowed to change these photos."
        case .unknown(let detail): detail
        }
    }

    /// Whether offering a retry makes sense. A too-large photo will never
    /// succeed on retry; a dropped connection will.
    var isRetryable: Bool {
        switch self {
        case .offline, .unknown: true
        case .tooLarge, .notFound, .unauthorized: false
        }
    }
}

/// Where profile photos live. Mirrored in `backend/storage.rules` — changing one
/// without the other breaks uploads.
enum StoragePath {
    static func photo(uid: String, photoId: String) -> String {
        "users/\(uid)/photos/\(photoId).jpg"
    }
}
