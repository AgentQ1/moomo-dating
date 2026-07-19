import Foundation

/// Photo storage for mock mode and tests.
///
/// This writes the bytes to a real file in the caches directory and hands back a
/// real path that really reads back. It is a different *destination*, not a
/// fake success: a photo that fails to write here fails here too, so the
/// upload-failure and reload paths are exercised for real without a bucket.
struct LocalPhotoUploadService: PhotoUploadService {

    /// Injected so tests can point at a scratch directory and assert on files.
    var root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mock-photos", isDirectory: true)
    }

    func upload(imageData: Data, uid: String, photoId: String) async throws -> String {
        let path = StoragePath.photo(uid: uid, photoId: photoId)
        let url = root.appendingPathComponent(path)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try imageData.write(to: url, options: .atomic)
        } catch {
            throw PhotoUploadError.unknown(error.localizedDescription)
        }
        return path
    }

    func data(at remotePath: String) async throws -> Data {
        let url = root.appendingPathComponent(remotePath)
        guard let data = try? Data(contentsOf: url) else {
            throw PhotoUploadError.notFound
        }
        return data
    }

    func delete(remotePath: String) async throws {
        let url = root.appendingPathComponent(remotePath)
        // Already absent is the desired end state.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
