import SwiftUI

#if canImport(LiveKit) && canImport(FirebaseFunctions)
import LiveKit

/// The other person's camera, filling whatever it is given.
///
/// `isRendering` is the renderer's own report that a frame has been painted,
/// not "a track object exists" — the call screen keeps its dark ground up
/// until this flips, so a subscribed track whose first frame is still in
/// flight never shows as an empty rectangle. It goes back to false when the
/// track disappears, which is the honest state ("no video").
///
/// `.fill` because this is full-bleed: a `fit` letterbox would put black bars
/// down the sides of a portrait phone. `.off` because mirroring is for looking
/// at yourself; the person you are talking to should be the way round they
/// actually are, including any writing behind them.
struct RemoteCallVideoLayer: View {
    @ObservedObject var media: LiveKitCallMediaService
    @Binding var isRendering: Bool

    var body: some View {
        if let track = media.remoteVideoTrack {
            SwiftUIVideoView(
                track,
                layoutMode: .fill,
                mirrorMode: .off,
                isRendering: $isRendering
            )
            .accessibilityLabel("Their video")
        } else {
            Color.clear
                .onAppear { isRendering = false }
        }
    }
}

/// The local camera in the corner self-view. Draws nothing until the local
/// track is published, letting the tile's placeholder show through.
///
/// Mirrored (`.auto` mirrors a front-facing camera and leaves the back one
/// alone), because a self-view that is not mirrored feels like looking at a
/// stranger — and it flips itself the right way round when the user flips the
/// camera.
struct LocalCallVideoLayer: View {
    @ObservedObject var media: LiveKitCallMediaService

    var body: some View {
        if let track = media.localVideoTrack {
            SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: .auto)
                .accessibilityLabel("Your camera preview")
        }
    }
}
#endif
