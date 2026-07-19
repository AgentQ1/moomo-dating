import SwiftUI
import UIKit

/// The full-screen matchmaking-and-call journey. Renders whatever stage the
/// model is in; every transition is the model's decision, never a view's.
struct CallFlowView: View {
    @ObservedObject var model: CallFlowModel
    @ObservedObject var coordinator: CallCoordinator

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            switch model.stage {
            case .searching:
                CallSearchingView(mode: model.mode) { model.cancel() }

            case .connecting(let candidate):
                CallConnectingView(candidate: candidate, mode: model.mode)

            case .active:
                ActiveCallView(model: model, onMinimise: { coordinator.minimise() })

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

    /// Search and connect run on the reference's dark navy; the live call is
    /// daylight cream per its reference; decision phases the cool canvas.
    private var background: some View {
        Group {
            switch model.stage {
            case .searching, .connecting:
                Palette.night
            case .active:
                Palette.cream
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

            Text(failure.isPermissionDenied ? "Moomo can't hear you yet" : "No luck this time")
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
