import SwiftUI

/// The icebreaker card, as it sits on a live video date.
///
/// Everything about this view is a constraint on how much room it is allowed
/// to take. It is a band across the bottom of the video card — never a sheet,
/// never full screen, never anything that pauses or shrinks the video. The
/// two faces stay exactly where they were, and mute, camera, the safety menu,
/// minimise, and End Call are all still where the user left them.
///
/// One tap answers. There is no confirm step, no scroll, and nothing to read
/// that cannot be read in the two seconds someone can spare while talking.
struct DateIcebreakerOverlay: View {
    @ObservedObject var session: DateIcebreakerSessionModel

    var body: some View {
        Group {
            switch session.stage {
            case .round(let round):
                card { roundContent(round) }
            case .summary(let summary):
                card { summaryContent(summary) }
            case .idle, .closed:
                EmptyView()
            }
        }
        .animation(Motion.transition, value: session.stage)
        .animation(Motion.transition, value: session.isRevealing)
    }

    // MARK: - Chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            content()
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .shadow(Shadows.card)
        .padding(.horizontal, Space.sm)
        .padding(.bottom, Space.sm)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("icebreaker.card")
    }

    private func header(_ label: String) -> some View {
        HStack(spacing: Space.xs) {
            Text(label)
                .font(Typography.caption)
                .tracking(Typography.sectionTracking)
                .foregroundStyle(Palette.textSecondary)

            Spacer()

            Button {
                session.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: Size.minTapTarget * 0.6, height: Size.minTapTarget * 0.6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close the icebreakers")
            .accessibilityIdentifier("icebreaker.close")
        }
    }

    // MARK: - A round

    @ViewBuilder
    private func roundContent(_ round: IcebreakerRound) -> some View {
        header("ICEBREAKER \(round.index + 1) OF \(session.totalRounds)")

        Text(round.headline(peerName: session.peerName))
            .font(Typography.rowTitleSmall)
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)

        switch round.phase {
        case .guessingPeer, .answering:
            options(round)

        case .waitingForPeer:
            HStack(spacing: Space.xs) {
                ProgressView().tint(Palette.textSecondary)
                Text("Locked in — waiting for \(session.peerName)…")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(minHeight: Size.minTapTarget * 0.7)
            .accessibilityIdentifier("icebreaker.waiting")

        case .revealed:
            reveal(round)

        case .unanswered:
            Text("That one ran out of time. No harm done.")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityIdentifier("icebreaker.unanswered")
        }

        if let notice = session.notice {
            Text(notice)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityIdentifier("icebreaker.notice")
        }
    }

    /// The answers. Two options sit side by side; three stack, because three
    /// across at this width would truncate every one of them.
    @ViewBuilder
    private func options(_ round: IcebreakerRound) -> some View {
        let indices = Array(round.prompt.options.indices)
        if indices.count <= 2 {
            HStack(spacing: Space.xs) {
                ForEach(indices, id: \.self) { optionButton(round, index: $0) }
            }
        } else {
            VStack(spacing: Space.xxs) {
                ForEach(indices, id: \.self) { optionButton(round, index: $0) }
            }
        }
    }

    private func optionButton(_ round: IcebreakerRound, index: Int) -> some View {
        Button {
            session.choose(index)
        } label: {
            Text(round.prompt.option(index))
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Size.minTapTarget)
                .padding(.horizontal, Space.xs)
                .background(
                    RoundedRectangle(cornerRadius: Radius.well, style: .continuous)
                        .fill(tint(for: round, index: index))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(round.prompt.option(index))
        .accessibilityIdentifier("icebreaker.option.\(index)")
    }

    /// Flag answers carry their colour; everything else is the neutral well,
    /// so no option ever looks like the one the app would prefer.
    private func tint(for round: IcebreakerRound, index: Int) -> Color {
        guard round.prompt.kind == .flag, let flag = IcebreakerFlag(rawValue: index) else {
            return Palette.iconWell
        }
        switch flag {
        case .red: return Palette.coral.opacity(0.16)
        case .yellow: return Palette.goldLight.opacity(0.28)
        case .green: return Palette.online.opacity(0.16)
        }
    }

    @ViewBuilder
    private func reveal(_ round: IcebreakerRound) -> some View {
        if let outcome = round.outcome {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Image(systemName: outcome.isAgreement ? "sparkles" : "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(outcome.isAgreement ? Palette.verifiedOlive : Palette.textSecondary)
                    Text(outcome.headline)
                        .font(Typography.bodyEmphasis)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(outcome.detail)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The flip: the card scales up for a beat as it turns over, so a
            // reveal reads as a reveal rather than as text quietly changing.
            .scaleEffect(session.isRevealing ? 1.03 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("icebreaker.reveal")
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private func summaryContent(_ summary: IcebreakerSummary) -> some View {
        header("YOU TWO DISCOVERED…")

        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(Array(summary.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: Space.xs) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(Palette.gold)
                        .padding(.top, 6)
                    Text(line)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("icebreaker.summary")
    }
}
