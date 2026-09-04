import SwiftUI
import UIKit

/// The full-screen matchmaking-and-call journey. Renders whatever stage the
/// model is in; every transition is the model's decision, never a view's.
struct CallFlowView: View {
    @ObservedObject var model: CallFlowModel
    @ObservedObject var coordinator: CallCoordinator
    /// The signed-in user, as the in-call experiences see them. Passed down
    /// from the tab shell rather than read from the environment: this screen
    /// lives in a full-screen cover, and a missing environment object there
    /// would be a crash rather than a missing name.
    var localPlayer: CallGameSeat = CallGameSeat(id: "", displayName: "You")

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            switch model.stage {
            case .searching:
                CallSearchingView(mode: model.mode) { model.cancel() }

            case .connecting(let candidate):
                CallConnectingView(candidate: candidate, mode: model.mode)

            case .active:
                ActiveCallView(
                    model: model,
                    onMinimise: { coordinator.minimise() },
                    localPlayer: localPlayer
                )

            case .deciding(let summary):
                CallDecisionView(model: model, summary: summary)

            case .likeSent(let summary):
                LikeSentView(summary: summary) { model.finish() }

            case .matched(let match):
                MatchCelebrationView(
                    match: match,
                    onSendMessage: {
                        model.finish()
                        coordinator.openConversation?(match.conversationID)
                    },
                    onKeepBrowsing: { model.finish() }
                )

            case .failed(let failure):
                CallFailedView(failure: failure) { model.cancel() }
            }
        }
        .animation(Motion.transition, value: model.stage)
    }

    /// Search, connect, and the live call all run on the dark navy; decision
    /// phases get the cool canvas.
    private var background: some View {
        Group {
            switch model.stage {
            case .searching, .connecting:
                Palette.night
            case .active:
                // Full-bleed video wants a dark ground behind it, not the
                // cream page the old card sat on.
                Palette.night
            case .deciding, .likeSent, .matched, .failed:
                Palette.canvas
            }
        }
    }
}

/// Permissions, search, connect, or media fell over. One honest message, one
/// way out — plus a Settings shortcut when Settings is where the fix lives.
struct CallFailedView: View {
    var failure: CallFailure
    var onDone: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: Space.md) {
            Spacer()

            Image(systemName: failure.isPermissionDenied ? "mic.slash.circle" : "phone.down.circle")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Palette.textSecondary)

            Text(failure.isPermissionDenied ? "Baybe can't hear you yet" : "No luck this time")
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.ink)

            Text(failure.message)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xxl)

            Spacer()

            if failure.isPermissionDenied {
                PrimaryButton(title: "Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .padding(.horizontal, Space.xxl)
                .accessibilityIdentifier("call.failed.settings")

                Button("Back to Discover", action: onDone)
                    .font(Typography.bodyEmphasis)
                    .foregroundStyle(Palette.ink)
                    .frame(minHeight: Size.minTapTarget)
                    .padding(.bottom, Space.xxl)
                    .accessibilityIdentifier("call.failed.done")
            } else {
                PrimaryButton(title: "Back to Discover", action: onDone)
                    .padding(.horizontal, Space.xxl)
                    .padding(.bottom, Space.xxl)
                    .accessibilityIdentifier("call.failed.done")
            }
        }
    }
}
