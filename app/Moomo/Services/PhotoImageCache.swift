import UIKit

/// Decoded profile photos, keyed by storage path.
///
/// Two jobs. It stops the grid re-downloading and re-decoding a photo on every
/// redraw, and it is primed with the compressed bytes at upload time — so a
/// photo you just added renders instantly instead of round-tripping to the
/// server to fetch what the device already has.
///
/// It stores *decoded* images, not bytes: SwiftUI needs a bitmap to draw, and
/// caching bytes meant every render path paid the JPEG decode again — on the
/// main actor, where it stalls frames. Decoding happens here, on the actor's
/// executor, exactly once per photo.
///
/// `NSCache` rather than a dictionary so it evicts under memory pressure.
actor PhotoImageCache {
    static let shared = PhotoImageCache()

    private let cache = NSCache<NSString, UIImage>()
    /// De-duplicates concurrent loads of the same path. Without this, a grid
    /// showing the same photo twice issues two downloads.
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    init() {
        // Decoded-pixel budget. Six 1080px profile photos ≈ 28 MB decoded.
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    /// Decode and cache encoded bytes (an upload's compressed JPEG, usually).
    func store(_ data: Data, for path: String) {
        guard let image = Self.decode(data) else { return }
        insert(image, for: path)
    }

    func cached(_ path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }

    func image(for path: String, using service: PhotoUploadService) async throws -> UIImage {
        if let hit = cached(path) { return hit }

        if let existing = inFlight[path] {
            return try await existing.value
        }

        let task = Task<UIImage, Error> {
            let data = try await service.data(at: path)
            guard let image = Self.decode(data) else {
                throw PhotoUploadError.unknown("That photo couldn't be displayed.")
            }
            return image
        }
        inFlight[path] = task
        defer { inFlight[path] = nil }

        let image = try await task.value
        insert(image, for: path)
        return image
    }

    func clear() {
        cache.removeAllObjects()
    }

    private func insert(_ image: UIImage, for path: String) {
        cache.setObject(image, forKey: path as NSString, cost: Self.pixelCost(of: image))
    }

    /// Decode up front (`preparingForDisplay`), so drawing the image later is
    /// a blit rather than a lazy JPEG decode on the main thread.
    private static func decode(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    private static func pixelCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.width * cgImage.height * 4
    }
}
