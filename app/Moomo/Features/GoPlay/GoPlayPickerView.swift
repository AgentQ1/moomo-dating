import SwiftUI
import UIKit

/// The Go Play picker, as it sits on a live call.
///
/// It floats over the video card rather than replacing it: nothing has been
/// agreed yet, so nothing should displace the call. Both faces stay up, and
/// mute, camera, the safety menu, minimise, and End Call are exactly where
/// they were — opening and closing this list is a purely local act that never
/// so much as touches the room.
struct GoPlayPickerView: View {
    @ObservedObject var session: GoPlaySessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text("PICK SOMETHING TO PLAY")
                    .font(Typography.caption)
                    .tracking(Typography.sectionTracking)
                    .foregroundStyle(Palette.textSecondary)

                Spacer()

                Button {
                    session.closePicker()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: Size.minTapTarget * 0.6, height: Size.minTapTarget * 0.6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close the game list")
                .accessibilityIdentifier("callgames.picker.close")
            }

            ForEach(CallGame.pickerOrder) { game in
                row(game)
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: 340)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .shadow(Shadows.cardLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("callgames.picker")
    }

    /// One game. Unbuilt ones stay on the list, dimmed and marked — a list
    /// that hides what is coming tells the user nothing, and one that lets
    /// them pick it wastes a call.
    private func row(_ game: CallGame) -> some View {
        Button {
            session.propose(game)
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: game.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(game.isPlayable ? Palette.mascotSageInk : Palette.textTertiary)
                    .frame(width: Size.iconLarge, height: Size.iconLarge)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.checkbox, style: .continuous)
                            .fill(Palette.iconWell)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(game.title)
                        .font(Typography.rowTitleSmall)
                        .foregroundStyle(game.isPlayable ? Palette.ink : Palette.textSecondary)
                    Text(game.tagline)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: Space.xs)

                if game.isPlayable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                } else {
                    Text("Soon")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.iconWell))
                }
            }
            .padding(.vertical, Space.xxs)
            .frame(minHeight: Size.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!game.isPlayable)
        .opacity(game.isPlayable ? 1 : 0.6)
        .accessibilityLabel(
            game.isPlayable
                ? "\(game.title). \(game.tagline)"
                : "\(game.title). Coming soon."
        )
        .accessibilityIdentifier("callgames.game.\(game.rawValue)")
    }
}

// MARK: - Invitation

/// "Play Icebreakers?" — the card the other person sees, and the waiting
/// state the proposer sees. Sits over the call's video card rather than
/// replacing it: the call is still the thing on screen until both sides say
/// yes.
struct GoPlayInvitationCard: View {
    @ObservedObject var session: GoPlaySessionModel

    var body: some View {
        VStack(spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Image(systemName: game?.symbol ?? "gamecontroller.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.gold)
                Text(title)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)
            }

            Text(subtitle)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)

            if isIncoming {
                HStack(spacing: Space.sm) {
                    Button("Not Now") { session.declineInvite() }
                        .buttonStyle(GoPlayInviteButtonStyle(isProminent: false))
                        .accessibilityLabel("Decline the game invitation")
                        .accessibilityIdentifier("callgames.invite.decline")

                    Button("Play") { session.acceptInvite() }
                        .buttonStyle(GoPlayInviteButtonStyle(isProminent: true))
                        .accessibilityLabel("Accept and play \(game?.title ?? "the game")")
                        .accessibilityIdentifier("callgames.invite.accept")
                }
            } else {
                HStack(spacing: Space.xs) {
                    ProgressView().tint(Palette.textSecondary)
                    Button("Cancel") { session.leaveGame() }
                        .font(Typography.bodyEmphasis)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(minHeight: Size.minTapTarget)
                        .accessibilityLabel("Cancel the game invitation")
                        .accessibilityIdentifier("callgames.invite.cancel")
                }
            }
        }
        .padding(Space.md)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .shadow(Shadows.cardLarge)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("callgames.invite")
        .onAppear {
            guard isIncoming else { return }
            UIAccessibility.post(notification: .announcement, argument: "\(title). \(subtitle)")
        }
    }

    private var isIncoming: Bool {
        if case .inviteReceived = session.stage { return true }
        return false
    }

    private var game: CallGame? {
        switch session.stage {
        case .invitePending(let game), .inviteReceived(let game), .playing(let game): game
        case .idle, .picking: nil
        }
    }

    private var title: String {
        guard let game else { return "Invite sent" }
        return isIncoming ? "Play \(game.title)?" : "Invite sent"
    }

    private var subtitle: String {
        isIncoming
            ? "\(session.peerName) wants to play while you talk."
            : "Waiting for \(session.peerName) to answer…"
    }
}

private struct GoPlayInviteButtonStyle: ButtonStyle {
    var isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.bodyEmphasis)
            .foregroundStyle(isProminent ? .white : Palette.ink)
            .padding(.horizontal, Space.lg)
            .frame(minHeight: Size.minTapTarget)
            .background(
                Capsule().fill(isProminent ? Palette.verifiedOlive : Palette.iconWell)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
