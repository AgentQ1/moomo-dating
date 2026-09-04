import Combine
import SwiftUI
import PhotosUI

/// Photo management outside onboarding: add, remove, reorder.
///
/// Owns a `PhotoUploadQueue` (the type onboarding uses, built for exactly
/// this reuse) and writes every settled change through
/// `SessionStore.updateProfile` — photos are server state and must never lag
/// in a local draft.
@MainActor
final class EditPhotosModel: ObservableObject {
    @Published private(set) var photos: [ProfilePhoto]

    private(set) var queue: PhotoUploadQueue!
    private var queueForwarding: AnyCancellable?

    let photoService: PhotoUploadService
    private let uid: String
    /// Persists the new photo array (via the session's single write path).
    /// Returns whether the save actually reached the backend.
    private let persist: ([ProfilePhoto]) async -> Bool
    /// The most recent save in the chain — each save awaits its predecessor,
    /// so edits can never land out of order (fire-and-forget saves raced:
    /// a slow earlier write could clobber a later one).
    private var saveTask: Task<Bool, Never>?

    static let maxPhotos = 6

    /// A profile cannot enter the app without a photo
    /// (`ProfileRequirements.missingFields`), so the editor must never be able
    /// to persist an empty list. Saving one flips `hasValidProfileState` to
    /// false and `SessionStore` re-derives `.onboarding`, dumping the user on
    /// the name step mid-edit — which is exactly what "changing" a
    /// single-photo profile used to do.
    static let minimumPhotos = 1

    /// False when the only photo left is the one keeping this profile valid.
    /// The view hides the remove control rather than letting the tap fail
    /// silently; replacing a sole photo means adding the new one first.
    var canRemovePhotos: Bool { photos.count > Self.minimumPhotos }

    init(
        uid: String,
        photos: [ProfilePhoto],
        photoService: PhotoUploadService = PhotoServiceFactory.make(),
        persist: @escaping ([ProfilePhoto]) async -> Bool
    ) {
        self.uid = uid
        self.photos = photos.sorted { $0.order < $1.order }
        self.photoService = photoService
        self.persist = persist

        queue = PhotoUploadQueue(
            uid: uid,
            service: photoService,
            currentPhotoCount: { [weak self] in self?.photos.count ?? 0 },
            onUploaded: { [weak self] photo in self?.addUploadedPhoto(photo) }
        )
        // The view observes THIS model only. It must never hold the queue as
        // its own `@ObservedObject`: the editor is re-inited on parent
        // renders, and an observed queue taken from a throwaway init
        // parameter splits the UI from the queue that owns the uploads.
        queueForwarding = queue.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    var remainingSlots: Int {
        max(0, Self.maxPhotos - photos.count - queue.items.count)
    }

    // Same semantics as onboarding's photo handling: insert at the order the
    // queue reserved at selection time, compact once the queue settles.
    private func addUploadedPhoto(_ photo: ProfilePhoto) {
        let index = photos.firstIndex { $0.order > photo.order } ?? photos.endIndex
        photos.insert(photo, at: index)
        if queue.items.isEmpty {
            renumber()
        }
        scheduleSave()
    }

    func removePhoto(id: String) {
        guard let photo = photos.first(where: { $0.id == id }) else { return }
        // Belt and braces with the view's hidden control: any other caller
        // (tests, a future bulk edit) must not be able to invalidate the
        // profile either.
        guard canRemovePhotos else { return }
        photos.removeAll { $0.id == id }
        renumber()
        let save = scheduleSave()

        // Bytes go ONLY after the profile write is confirmed: deleting first
        // and failing to persist would leave the live profile pointing at a
        // photo whose bytes are gone. A failed save orphans bytes instead —
        // the safe direction; account deletion sweeps them.
        Task { [photoService] in
            guard await save.value else { return }
            try? await photoService.delete(remotePath: photo.remotePath)
        }
    }

    func movePhotos(from source: IndexSet, to destination: Int) {
        photos.move(fromOffsets: source, toOffset: destination)
        renumber()
        scheduleSave()
    }

    /// Chains the save after any in-flight one and returns it, so callers can
    /// await confirmation. Never fire-and-forget.
    @discardableResult
    private func scheduleSave() -> Task<Bool, Never> {
        let snapshot = photos
        let previous = saveTask
        let persist = persist
        let task = Task {
            _ = await previous?.value
            return await persist(snapshot)
        }
        saveTask = task
        return task
    }

    /// Test seam: resolves once every save scheduled so far has settled.
    func waitForPendingSaves() async {
        _ = await saveTask?.value
    }

    private func renumber() {
        for index in photos.indices {
            photos[index].order = index
        }
    }
}

struct EditPhotosView: View {
    // The single observed object. The queue's changes arrive through the
    // model's forwarding — holding the queue separately here re-introduced
    // the identity bug where the view rendered a throwaway model's queue
    // while uploads ran on the state object's.
    @StateObject private var model: EditPhotosModel

    @State private var selection: [PhotosPickerItem] = []
    @State private var isReordering = false
    @State private var loadFailureMessage: String?

    init(model: @autoclosure @escaping () -> EditPhotosModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                if isReordering {
                    reorderList
                } else {
                    grid
                }

                // Without this the missing ✕ on a sole photo reads as a bug.
                Text(
                    model.canRemovePhotos
                        ? "Your first photo is your main one."
                        : "Your first photo is your main one. To swap it, add another photo first — your profile needs at least one."
                )
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityIdentifier("editPhotos.hint")

                if let loadFailureMessage {
                    Label(loadFailureMessage, systemImage: "exclamationmark.circle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.coral)
                }

                if model.photos.count > 1 {
                    Button(isReordering ? "Done reordering" : "Reorder") {
                        withAnimation(Motion.transition) { isReordering.toggle() }
                    }
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.blue)
                    .accessibilityIdentifier("editPhotos.reorder")
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.md)
        }
        .background(Palette.canvas)
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await ingest(items)
                selection = []
            }
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 100), spacing: Space.sm)],
            spacing: Space.sm
        ) {
            ForEach(model.photos) { photo in
                photoTile(photo)
            }

            // Keyed by `gridID`, never `id`: a queue item and the photo it
            // becomes share an id, and one LazyVGrid fed both identities keeps
            // the stale pending tile forever (the onboarding grid bug).
            ForEach(model.queue.items, id: \.gridID) { item in
                pendingTile(item)
            }

            if model.remainingSlots > 0 {
                PhotosPicker(
                    selection: $selection,
                    maxSelectionCount: model.remainingSlots,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
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
                .accessibilityIdentifier("editPhotos.add")
                .accessibilityLabel("Add photo")
            }
        }
    }

    private func photoTile(_ photo: ProfilePhoto) -> some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                RemotePhotoView(remotePath: photo.remotePath, service: model.photoService)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .accessibilityElement()
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(photo.order == 0 ? "Main photo" : "Photo \(photo.order + 1)")
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
            .overlay(alignment: .topTrailing) {
                // Offered only when removal can actually succeed. On a
                // single-photo profile the remove would empty the list, and a
                // photo-less profile is routed straight back to onboarding.
                if model.canRemovePhotos {
                    Button {
                        model.removePhoto(id: photo.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white, Palette.ink.opacity(0.5))
                            .padding(6)
                    }
                    .accessibilityLabel("Remove photo")
                }
            }
    }

    private func pendingTile(_ item: PhotoUploadQueue.Item) -> some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                ZStack {
                    if let image = item.preview {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Palette.blueTint
                    }
                    Palette.ink.opacity(0.45)
                    if item.failure == nil {
                        ProgressView().tint(.white)
                    } else {
                        Button("Retry") { model.queue.retry(item.id) }
                            .font(Typography.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Palette.blue))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button {
                    model.queue.discard(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white, Palette.ink.opacity(0.5))
                        .padding(6)
                }
                .accessibilityLabel("Cancel upload")
            }
            .accessibilityLabel(item.failure == nil ? "Photo uploading" : "Photo failed to upload")
    }

    private var reorderList: some View {
        List {
            ForEach(model.photos) { photo in
                HStack(spacing: Space.sm) {
                    RemotePhotoView(remotePath: photo.remotePath, service: model.photoService)
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
        .frame(height: CGFloat(model.photos.count) * 74 + 8)
    }

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

        await model.queue.add(raw)
    }
}
