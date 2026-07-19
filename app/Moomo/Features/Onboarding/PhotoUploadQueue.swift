import Foundation
import SwiftUI

/// Compresses and uploads picked photos, and holds the state of the ones still
/// in flight.
///
/// The rule this type exists to enforce: **a photo only becomes a
/// `ProfilePhoto` after its bytes are stored.** Until then it lives here as an
/// `Item` with a preview and a state. Nothing in flight, and nothing that
/// failed, is ever handed to `onUploaded` — so the profile cannot contain a
/// photo the server has never seen.
///
/// Owned by whoever is editing photos (onboarding today, the profile editor in
/// Phase 3), so both get the same behaviour without sharing state.
@MainActor
final class PhotoUploadQueue: ObservableObject {

    struct Item: Identifiable, Equatable {
        let id: String
        /// Compressed JPEG bytes — what retry re-uploads.
        let previewData: Data
        /// The same bytes pre-decoded off the main actor, so the pending tile
        /// draws without `body` paying a JPEG decode on every update.
        let preview: UIImage?
        var state: State

        /// View identity for grids that also show uploaded photos. The
        /// `ProfilePhoto` this item becomes keeps the same `id`; rendering
        /// both under one identity makes SwiftUI reuse the pending tile for
        /// the uploaded photo, which shows as an upload stuck forever.
        var gridID: String { "pending-\(id)" }

        enum State: Equatable {
            case uploading
            case failed(PhotoUploadError)
        }

        var failure: PhotoUploadError? {
            if case .failed(let error) = state { return error }
            return nil
        }
    }

    @Published private(set) var items: [Item] = []

    private let service: PhotoUploadService
    private let uid: String
    /// Called once per successful upload, on the main actor.
    private let onUploaded: (ProfilePhoto) -> Void
    /// How many photos the owner already holds. Reserved orders start above
    /// both this and every reservation already handed out.
    private let currentPhotoCount: () -> Int

    private var tasks: [String: Task<Void, Never>] = [:]
    /// Order values reserved for photos still in flight, keyed by item id.
    ///
    /// Reserved **at selection time**, in selection order — never at upload
    /// completion. Uploads run concurrently and a small second photo can finish
    /// before a large first one; assigning order on completion is how the
    /// user's chosen primary photo silently became photo two.
    private var reservedOrders: [String: Int] = [:]
    /// Monotonic within the queue's lifetime, so reservations from overlapping
    /// batches can never collide.
    private var nextReservedOrder = 0

    init(
        uid: String,
        service: PhotoUploadService,
        currentPhotoCount: @escaping () -> Int,
        onUploaded: @escaping (ProfilePhoto) -> Void
    ) {
        self.uid = uid
        self.service = service
        self.currentPhotoCount = currentPhotoCount
        self.onUploaded = onUploaded
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    var isUploading: Bool {
        items.contains { $0.state == .uploading }
    }

    var hasFailures: Bool {
        items.contains { $0.failure != nil }
    }

    // MARK: - Adding

    /// A whole batch compressing and uploading at once spikes CPU, memory, and
    /// the radio; this many at a time keeps the pipeline busy without the burst.
    private static let maxConcurrentIngests = 3

    /// Compresses off the main actor, then uploads. Returns once every photo has
    /// settled, so callers can await a batch.
    ///
    /// Each image's final `order` is reserved here, in selection order, before
    /// any concurrent work starts — so however the uploads interleave, the
    /// photos land in the order the user picked them.
    func add(_ rawImages: [Data]) async {
        let batch: [(id: String, raw: Data)] = rawImages.map { (UUID().uuidString, $0) }

        nextReservedOrder = max(nextReservedOrder, currentPhotoCount() + items.count)
        for entry in batch {
            reservedOrders[entry.id] = nextReservedOrder
            nextReservedOrder += 1
        }

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func startNext() {
                guard next < batch.count else { return }
                let entry = batch[next]
                next += 1
                group.addTask { [weak self] in
                    await self?.ingest(entry.raw, id: entry.id)
                }
            }

            for _ in 0..<Self.maxConcurrentIngests { startNext() }
            while await group.next() != nil { startNext() }
        }
    }

    private func ingest(_ raw: Data, id: String) async {
        // Compression and the preview decode are CPU-bound and would jank the
        // picker dismissal if they ran on the main actor. A 4000px photo takes
        // ~100ms to compress.
        let compressed: Data
        let preview: UIImage?
        do {
            (compressed, preview) = try await Task.detached(priority: .userInitiated) {
                let data = try ImageCompressor.compress(raw)
                let image = UIImage(data: data)
                return (data, image?.preparingForDisplay() ?? image)
            }.value
        } catch {
            // Unreadable images never reach an upload; surface immediately.
            // (If compression couldn't read it, a preview decode won't either.)
            insert(Item(
                id: id,
                previewData: raw,
                preview: nil,
                state: .failed(.unknown(
                    (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                ))
            ))
            return
        }

        guard !Task.isCancelled else {
            reservedOrders[id] = nil
            return
        }

        insert(Item(id: id, previewData: compressed, preview: preview, state: .uploading))
        await performUpload(id: id, data: compressed)
    }

    /// Places the item among its batch-mates by reserved order, so the pending
    /// tiles appear in selection order even though compression finishes in
    /// whatever order it likes.
    private func insert(_ item: Item) {
        let order = reservedOrders[item.id] ?? Int.max
        let index = items.firstIndex { (reservedOrders[$0.id] ?? Int.max) > order }
            ?? items.endIndex
        items.insert(item, at: index)
    }

    private func performUpload(id: String, data: Data) async {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let path = try await service.upload(imageData: data, uid: uid, photoId: id)
                guard !Task.isCancelled else { return }

                // Prime the cache before publishing the photo, so the grid never
                // re-fetches bytes it already has.
                await PhotoImageCache.shared.store(data, for: path)

                // Settled — stop tracking here first, so the owner sees an
                // up-to-date queue when the photo lands.
                let order = reservedOrders[id] ?? currentPhotoCount()
                reservedOrders[id] = nil
                items.removeAll { $0.id == id }

                onUploaded(ProfilePhoto(id: id, remotePath: path, order: order))
            } catch let error as PhotoUploadError {
                guard !Task.isCancelled else { return }
                setState(.failed(error), for: id)
            } catch {
                guard !Task.isCancelled else { return }
                setState(.failed(.unknown(error.localizedDescription)), for: id)
            }
        }
        tasks[id] = task
        await task.value
        tasks[id] = nil
    }

    // MARK: - Recovery

    func retry(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), item.failure != nil else { return }
        setState(.uploading, for: id)
        Task { await performUpload(id: id, data: item.previewData) }
    }

    /// Drop a failed or in-flight upload. Cancels the transfer if it's running.
    func discard(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        reservedOrders[id] = nil
        items.removeAll { $0.id == id }
    }

    private func setState(_ state: Item.State, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }
}
