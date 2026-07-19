import SwiftUI

// MARK: - Like / Pass

/// The after-call decision. No skipping: a speed call always ends in a
/// choice, that's the product.
struct CallDecisionView: View {
    @ObservedObject var model: CallFlowModel
    var summary: CallSummary

    @State private var isReporting = false
    @State private var isConfirmingBlock = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Call ended!")
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.ink)

            Text(summary.endReason == .timeExpired
                 ? "Three minutes, gone already."
                 : "You talked for \(formattedDuration).")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, Space.xxs)

            AvatarView(name: summary.candidate.displayName, photoPath: summary.candidate.photoPath, size: Size.decisionAvatar)
                .overlay(Circle().stroke(.white, lineWidth: 4))
                .shadow(Shadows.avatar)
                .padding(.top, Space.xl)

            VStack(spacing: Space.xxs) {
                Text("\(summary.candidate.displayName), \(summary.candidate.age)")
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)
                Text(summary.candidate.city)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.top, Space.sm)
            .accessibilityElement(children: .combine)

            Text("Want to keep talking to \(summary.candidate.displayName)?")
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, Space.lg)

            Spacer()

            if let failure = model.actionFailure {
                ValidationMessage(message: failure)
                    .padding(.bottom, Space.xs)
            }

            decisionButtons

            safetyRow
                .padding(.top, Space.md)
                .padding(.bottom, Space.xl)
        }
        .padding(.horizontal, Space.gutter)
        .sheet(isPresented: $isReporting) {
            ReportUserSheet(
                candidateName: summary.candidate.displayName,
                didSubmit: model.didSubmitReport,
                failure: model.actionFailure,
                onSubmit: { reason, details in
                    Task { await model.submitReport(reason: reason, details: details) }
                }
            )
        }
        .confirmationDialog(
            "Block \(summary.candidate.displayName)?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) {
                Task { await model.blockAndFinish() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They disappear from Discover, matches, and chat, and they won't be told.")
        }
    }

    private var decisionButtons: some View {
        HStack(spacing: Space.sm) {
            Button {
                Task { await model.decide(.pass) }
            } label: {
                Label("Pass", systemImage: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: Size.primaryCTAHeight)
                    .background(Capsule().fill(Palette.surface))
                    .shadow(Shadows.card)
            }
            .buttonStyle(.plain)
            .disabled(model.isSubmittingDecision)
            .accessibilityIdentifier("call.decision.pass")

            Button {
                Task { await model.decide(.like) }
            } label: {
                Group {
                    if model.isSubmittingDecision {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                    } else {
                        Label("Like", systemImage: "heart.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: Size.primaryCTAHeight)
                .background(Capsule().fill(Palette.coral))
                .shadow(Shadows.coralCTA)
            }
            .buttonStyle(.plain)
            .disabled(model.isSubmittingDecision)
            .accessibilityIdentifier("call.decision.like")
        }
    }

    private var safetyRow: some View {
        HStack(spacing: Space.lg) {
            Button("Report") { isReporting = true }
                .accessibilityIdentifier("call.decision.report")
            Button("Block") { isConfirmingBlock = true }
                .accessibilityIdentifier("call.decision.block")
        }
        .font(Typography.body)
        .foregroundStyle(Palette.textSecondary)
    }

    private var formattedDuration: String {
        let seconds = Int(summary.duration.rounded())
        if seconds < 60 { return "\(seconds) seconds" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

// MARK: - Like sent

/// Liked, not (yet) mutual. Honest about what happens next.
struct LikeSentView: View {
    var summary: CallSummary
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: Space.md) {
            Spacer()

            Image(systemName: "heart.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Palette.coral)

            Text("Like sent")
                .font(Typography.heroTitle)
                .foregroundStyle(Palette.ink)

            Text("If \(summary.candidate.displayName) likes you back, you'll match and can chat.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xxl)

            Spacer()

            PrimaryButton(title: "Back to Discover", action: onDone)
                .padding(.horizontal, Space.xxl)
                .padding(.bottom, Space.xxl)
                .accessibilityIdentifier("call.likeSent.done")
        }
    }
}

// MARK: - It's a Match

struct MatchCelebrationView: View {
    var match: Match
    var onSendMessage: () -> Void
    var onKeepBrowsing: () -> Void

    @EnvironmentObject private var session: SessionStore
    @State private var celebrate = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                AvatarView(name: match.candidate.displayName, photoPath: match.candidate.photoPath, size: Size.decisionAvatar)
                    .overlay(Circle().stroke(.white, lineWidth: 4))
                    .offset(x: -36)
                Image(systemName: "heart.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Palette.coral)
                    .offset(y: 46)
                AvatarView(
                    name: session.user?.profile.displayName ?? "You",
                    photoPath: session.user?.profile.primaryPhotoPath,
                    size: Size.decisionAvatar
                )
                .overlay(Circle().stroke(.white, lineWidth: 4))
                .offset(x: 36)
            }
            .scaleEffect(celebrate ? 1 : 0.7)
            .shadow(Shadows.avatar)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(Motion.celebrate) { celebrate = true }
            }

            Text("It's a Match!")
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.ink)
                .padding(.top, Space.xl)

            Text("You and \(match.candidate.displayName) liked each other.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, Space.xxs)

            Spacer()

            PrimaryButton(title: "Send a message", icon: "paperplane.fill", action: onSendMessage)
                .accessibilityIdentifier("call.match.sendMessage")

            Button("Keep browsing", action: onKeepBrowsing)
                .font(Typography.rowTitle)
                .foregroundStyle(Palette.textSecondary)
                .frame(height: Size.minTapTarget)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.xl)
                .accessibilityIdentifier("call.match.keepBrowsing")
        }
        .padding(.horizontal, Space.xxl)
    }
}
