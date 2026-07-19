import SwiftUI

// MARK: - Permissions

struct CameraMicStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ExplainerRow(
                icon: "video.fill",
                title: "Camera",
                detail: "For video speed calls. Nothing is ever recorded or stored."
            )
            ExplainerRow(
                icon: "mic.fill",
                title: "Microphone",
                detail: "For voice and video calls. Audio is peer-to-peer and never saved."
            )
            ExplainerRow(
                icon: "hand.raised.fill",
                title: "You're in control",
                detail: "Mute or leave any call at any time. We'll ask for access when your first call starts — not now."
            )
        }
        .onAppear {
            // Marks the explainer as seen. The system prompt is deliberately
            // not triggered here: iOS gives one chance to ask, and asking
            // before the reason is understood is how apps get denied forever.
            model.markPermissionExplainerSeen()
        }
    }
}

struct NotificationsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ExplainerRow(
                icon: "bell.badge.fill",
                title: "Someone wants to talk",
                detail: "We'll let you know when a match is waiting for you."
            )
            ExplainerRow(
                icon: "heart.fill",
                title: "It's a match",
                detail: "When you both say yes, you get 24 hours to chat."
            )
            ExplainerRow(
                icon: "hourglass",
                title: "Chat expiring",
                detail: "A nudge before a conversation runs out."
            )
            Text("Moomo asks for permission before sending your first notification — not now. You can change it any time in Settings.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, Space.xs)
        }
    }
}

struct ExplainerRow: View {
    var icon: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            ZStack {
                Circle()
                    .fill(Palette.blueTint)
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: Size.iconMedium))
                    .foregroundStyle(Palette.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.rowTitleSmall)
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Safety

struct SafetyStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ExplainerRow(
                icon: "person.fill.checkmark",
                title: "Be yourself",
                detail: "Real name, real photos, real you. Impersonation gets removed."
            )
            ExplainerRow(
                icon: "hand.thumbsup.fill",
                title: "Be kind",
                detail: "Harassment, hate, and nudity are never OK and end in removal."
            )
            ExplainerRow(
                icon: "flag.fill",
                title: "Report anything off",
                detail: "If someone makes you uncomfortable, tell us at support@moomo.app. We read every report."
            )
            ExplainerRow(
                icon: "eye.slash.fill",
                title: "Never record",
                detail: "Recording someone without consent is against the rules and often the law."
            )

            Toggle(isOn: Binding(
                get: { model.draft.acknowledgedSafety },
                set: { model.setSafetyAcknowledged($0) }
            )) {
                Text("I understand and agree to the community guidelines.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(Palette.blue)
            .padding(.top, Space.xs)
        }
    }
}
