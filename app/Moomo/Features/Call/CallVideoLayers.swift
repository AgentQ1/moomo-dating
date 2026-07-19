import SwiftUI

#if canImport(LiveKit) && canImport(FirebaseFunctions)
import LiveKit

/// The other person's live camera, rendered over the avatar once their track
/// arrives. Draws nothing until then — the avatar underneath stays visible,
/// which is also the honest state ("no video yet").
struct RemoteCallVideoLayer: View {
    @ObservedObject var media: LiveKitCallMediaService

    var body: some View {
        if let track = media.remoteVideoTrack {
            SwiftUIVideoView(track)
                .accessibilityLabel("Their video")
        }
    }
}

/// The local camera in the corner "you" tile. Draws nothing until the local
/// track is published, letting the tile's placeholder show through.
struct LocalCallVideoLayer: View {
    @ObservedObject var media: LiveKitCallMediaService

    var body: some View {
        if let track = media.localVideoTrack {
            SwiftUIVideoView(track)
                .accessibilityLabel("Your camera preview")
        }
    }
}
#endif
