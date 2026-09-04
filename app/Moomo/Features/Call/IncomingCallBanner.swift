import SwiftUI
import UIKit

/// The incoming-ring banner: a floating card at the top safe area, up only
/// while someone is ringing (foreground-only — there is no push path). Who is
/// calling, which kind of call, and the two honest answers.
struct IncomingCallBanner: View {
    var invite: CallInvite
    var onAccept: () -> Void
    var onDecline: () -> Void

    /// Every ringable call is a video call — `IncomingCallModel` declines the
    /// retired voice-only mode before a banner can exist for it. The fallback
    /// stays generic rather than naming a product that is gone.
    private var modeIcon: String {
        invite.mode == .video ? "video.fill" : "phone.fill"
    }

    private var subtitle: String {
        invite.mode == .video ? "Incoming Video Call" : "Incoming Call"
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            callerAvatar

            VStack(alignment: .leading, spacing: 2) {
                Text(invite.caller.displayName)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: Space.xs)

            Button(action: onDecline) {
                answerControl(icon: "xmark", fill: Palette.coral)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decline call from \(invite.caller.displayName)")
            .accessibilityIdentifier("call.incoming.decline")

            Button(action: onAccept) {
                answerControl(icon: modeIcon, fill: Palette.online)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Accept \(invite.mode == .video ? "video " : "")call from \(invite.caller.displayName)"
            )
            .accessibilityIdentifier("call.incoming.accept")
        }
        .padding(.horizontal, Space.md)
        .padding(.top, Space.lg)
        .padding(.bottom, Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.callCard, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(alignment: .top) {
            // The reference's drag-handle affordance.
            Capsule()
                .fill(Palette.checkboxBorder)
                .frame(width: 36, height: 5)
                .padding(.top, Space.xs)
                .accessibilityHidden(true)
        }
        .shadow(Shadows.cardLarge)
        .onAppear {
            // One nudge as the ring lands — the app's only other haptic is
            // the tab bar's, likewise an inline UIKit generator.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            // A ring is on a 7-second clock; a VoiceOver user must hear it
            // land, not discover it by touch after it's gone.
            UIAccessibility.post(
                notification: .announcement,
                argument: "\(subtitle) from \(invite.caller.displayName)"
            )
        }
        .accessibilityIdentifier("call.incoming.banner")
    }

    private var callerAvatar: some View {
        AvatarView(
            name: invite.caller.displayName,
            photoPath: invite.caller.photoPath,
            size: 56
        )
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(Palette.online)
                Image(systemName: modeIcon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(Palette.surface, lineWidth: 2))
            .offset(x: 2, y: 2)
            .accessibilityHidden(true)
        }
    }

    private func answerControl(icon: String, fill: Color) -> some View {
        ZStack {
            Circle().fill(fill)
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: Size.minTapTarget, height: Size.minTapTarget)
        .contentShape(Circle())
    }
}

#Preview {
    VStack(spacing: Space.md) {
        IncomingCallBanner(
            invite: CallInvite(
                id: "u-1",
                caller: DiscoveryCandidate(
                    id: "u-1", displayName: "Kenji", age: 26, city: "Chicago",
                    photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .he
                ),
                mode: .video,
                expiresAt: Date().addingTimeInterval(10)
            ),
            onAccept: {},
            onDecline: {}
        )
        IncomingCallBanner(
            invite: CallInvite(
                id: "u-2",
                caller: DiscoveryCandidate(
                    id: "u-2", displayName: "Anaya", age: 24, city: "Chicago",
                    photoPath: nil, isOnline: true, wantsToTalk: false, pronoun: .she
                ),
                mode: .video,
                expiresAt: Date().addingTimeInterval(10)
            ),
            onAccept: {},
            onDecline: {}
        )
    }
    .padding(.horizontal, Space.md)
    .frame(maxHeight: .infinity)
    .background(Palette.canvas)
}
