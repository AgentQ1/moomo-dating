import SwiftUI

/// Renders a photo from its storage path.
///
/// Goes through `PhotoImageCache`, so a photo the user just uploaded draws from
/// the bytes already in memory rather than being downloaded back. `AsyncImage`
/// is not usable here: these paths are not public URLs, and reading them needs
/// the Firebase SDK's auth.
struct RemotePhotoView<Placeholder: View>: View {
    var remotePath: String
    var service: PhotoUploadService
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                placeholder()
                    .overlay {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 20))
                            .foregroundStyle(Palette.textTertiary)
                    }
            } else {
                placeholder()
            }
        }
        .task(id: remotePath) {
            await load()
        }
    }

    private func load() async {
        failed = false
        // The decode happens inside the cache, off the main actor — decoding
        // here stalled frames for every photo that scrolled in.
        let path = remotePath
        do {
            let decoded = try await PhotoImageCache.shared.image(for: path, using: service)
            // The path can change while the await is parked; a stale result
            // must not flash the wrong photo into the tile.
            guard path == remotePath else { return }
            image = decoded
        } catch {
            guard path == remotePath else { return }
            // Genuinely failed to load. Showing a broken-image marker is
            // honest; showing an empty tile would look like no photo exists.
            failed = true
        }
    }
}

extension RemotePhotoView where Placeholder == AnyView {
    /// The common case: brand-tinted tile while loading.
    init(remotePath: String, service: PhotoUploadService) {
        self.init(remotePath: remotePath, service: service) {
            AnyView(Palette.blueTint)
        }
    }
}
