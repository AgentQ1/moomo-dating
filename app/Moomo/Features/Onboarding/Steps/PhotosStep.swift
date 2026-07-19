import SwiftUI
import PhotosUI

// MARK: - Photos

struct PhotosStep: View {
    @ObservedObject var model: OnboardingModel
    /// The queue lives on the model; observed here so upload state redraws.
    @ObservedObject private var queue: PhotoUploadQueue

    @State private var selection: [PhotosPickerItem] = []
    @State private var isReordering = false
    /// Set when picked items couldn't be loaded (iCloud originals not on
    /// device, usually). Cleared on the next pick.
    @State private var loadFailureMessage: String?

    static let maxPhotos = 6

    init(model: OnboardingModel) {
        self.model = model
        self.queue = model.photoQueue
    }

    private var remainingSlots: Int {
        max(0, Self.maxPhotos - model.draft.profile.photos.count - queue.items.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // Reordering needs a List for SwiftUI's drag machinery, but a grid
            // reads far better for photos. Rather than fake a drag in the grid,
            // the step swaps to an explicit reorder list — the same gesture
            // users already know from Photos.
            if isReordering {
                reorderList
            } else {
                grid
            }

            footerText

            if !model.draft.profile.photos.isEmpty {
                Button(isReordering ? "Done reordering" : "Reorder") {
                    withAnimation(Motion.transition) { isReordering.toggle() }
                }
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.blue)
                .accessibilityIdentifier("photos.reorder")
            }
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await ingest(items)
                selection = []
            }
        }
    }

    // MARK: - Grid

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 100), spacing: Space.sm)],
            spacing: Space.sm
        ) {
            ForEach(model.draft.profile.photos) { photo in
                UploadedPhotoSlot(
                    photo: photo,
                    service: model.photoDisplayService,
                    onRemove: { model.removePhoto(id: photo.id) }
                )
            }

            // Keyed by `gridID`, not `id`. A queue item and the `ProfilePhoto`
            // it becomes share the same `id`, and both ForEach loops feed the
            // same LazyVGrid — with the raw id, SwiftUI matches the uploaded
            // photo to the old pending tile's identity and keeps showing the
            // stale "uploading" view forever.
            ForEach(queue.items, id: \.gridID) { item in
                PendingPhotoSlot(
                    item: item,
                    onRetry: { queue.retry(item.id) },
                    onDiscard: { queue.discard(item.id) }
                )
            }

            if remainingSlots > 0 {
                PhotosPicker(
                    selection: $selection,
                    maxSelectionCount: remainingSlots,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    AddPhotoTile()
                }
                .accessibilityIdentifier("photos.add")
                .accessibilityLabel("Add photo")
            }
        }
    }

    private var reorderList: some View {
        List {
            ForEach(model.draft.profile.photos) { photo in
                HStack(spacing: Space.sm) {
                    RemotePhotoView(
                        remotePath: photo.remotePath,
                        service: model.photoDisplayService
                    )
                    .frame(width: 44, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.tile / 2, style: .continuous))

                    Text(photo.order == 0 ? "Main photo" : "Photo \(photo.order + 1)")
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)

                    Spacer()
                }
                .listRowBackground(Palette.surface)
            }
            .onMove { source, destination in
                model.movePhotos(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .frame(height: CGFloat(model.draft.profile.photos.count) * 74 + 8)
        .accessibilityIdentifier("photos.reorderList")
    }

    private var footerText: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Your first photo is your main one.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)

            if queue.isUploading {
                Text("Uploading… you can keep going, but you'll need at least one photo to finish.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }

            if let loadFailureMessage {
                Label(loadFailureMessage, systemImage: "exclamationmark.circle.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.coral)
                    .accessibilityIdentifier("photos.loadFailure")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Ingest

    /// Loads the picked items' bytes, then hands them to the queue.
    ///
    /// A picked item can fail to load — iCloud Photos originals aren't always on
    /// device. Those are dropped with the rest still processed, rather than
    /// failing the whole batch — but the user is told how many didn't make it,
    /// so photos never just silently vanish from their selection.
    private func ingest(_ items: [PhotosPickerItem]) async {
        var raw: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                raw.append(data)
            }
        }

        let dropped = items.count - raw.count
        loadFailureMessage = dropped == 0 ? nil : (
            dropped == 1
                ? "One photo couldn't be loaded. Check that it's downloaded from iCloud and try again."
                : "\(dropped) photos couldn't be loaded. Check that they're downloaded from iCloud and try again."
        )

        await queue.add(raw)
    }
}

// MARK: - Slots

/// Sizes a tile to the grid cell at a 3:4 ratio and clips its contents.
///
/// `Color.clear.aspectRatio(_:contentMode: .fit)` is what establishes the size:
/// applying `.aspectRatio(contentMode: .fill)` to the image itself makes it
/// *expand* to fill its parent instead, which overflows the cell and paints over
/// the rest of the grid.
private struct PhotoTile<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay { content() }
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

/// A photo whose bytes are stored. Holding one of these is proof of upload.
private struct UploadedPhotoSlot: View {
    var photo: ProfilePhoto
    var service: PhotoUploadService
    var onRemove: () -> Void

    var body: some View {
        PhotoTile {
            RemotePhotoView(remotePath: photo.remotePath, service: service)
        }
        // The identifier goes on the tile itself, as a leaf element, before the
        // overlays are attached. `.accessibilityElement(children: .contain)`
        // makes this a *container*, and containers are not addressable by
        // identifier from XCUITest — the element then exists on screen but
        // matches no query at all.
        .accessibilityElement()
        // The trait is load-bearing, not decoration. The tile's subtree is a
        // `Color.clear` and a plain `Image`, neither of which is accessible on
        // its own — without a trait SwiftUI publishes no element at all, and the
        // identifier below matches nothing despite the photo being on screen.
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(photo.order == 0 ? "Main photo" : "Photo \(photo.order + 1)")
        .accessibilityIdentifier("photos.uploaded.\(photo.order)")
        .overlay(alignment: .bottomLeading) {
            if photo.order == 0 {
                Text("MAIN")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.blue))
                    .padding(8)
            }
        }
        // Outside the accessibility element above, so it stays its own control
        // for VoiceOver rather than being swallowed by the tile.
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, Palette.ink.opacity(0.5))
                    .padding(6)
            }
            .accessibilityLabel("Remove photo")
            .accessibilityIdentifier("photos.remove.\(photo.order)")
        }
    }
}

/// A photo that is uploading or has failed. Visibly distinct from an uploaded
/// one — a dimmed tile with a spinner is the honest signal that this photo does
/// not count yet.
private struct PendingPhotoSlot: View {
    var item: PhotoUploadQueue.Item
    var onRetry: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        PhotoTile {
            ZStack {
                // Pre-decoded by the queue — decoding previewData here would
                // pay a JPEG decode inside `body` on every view update.
                if let image = item.preview {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Palette.blueTint
                }
                // Dimmed on purpose: a pending photo must not look like a
                // finished one, because it does not count yet.
                Palette.ink.opacity(0.45)
                if item.failure == nil { ProgressView().tint(.white) }
            }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(item.failure == nil ? "Photo uploading" : "Photo failed to upload")
        .accessibilityIdentifier(item.failure == nil ? "photos.uploading" : "photos.failed")
        // Retry must stay its own control, so it sits outside the tile's
        // accessibility element rather than inside it.
        .overlay {
            if let failure = item.failure {
                failureOverlay(failure)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDiscard) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, Palette.ink.opacity(0.5))
                    .padding(6)
            }
            .accessibilityLabel("Cancel upload")
        }
    }

    @ViewBuilder
    private func failureOverlay(_ failure: PhotoUploadError) -> some View {
        VStack(spacing: Space.xxs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)

            if failure.isRetryable {
                Button("Retry", action: onRetry)
                    .font(Typography.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.blue))
                    .accessibilityIdentifier("photos.retry")
            } else {
                // Not retryable — saying so is more use than a button that
                // would fail the same way again.
                Text(failure.errorDescription ?? "Failed")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
        }
    }
}

private struct AddPhotoTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
            .strokeBorder(
                Palette.checkboxBorder,
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Palette.blue)
            }
    }
}
