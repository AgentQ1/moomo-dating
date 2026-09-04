import SwiftUI

/// The onboarding container: progress rail, step content, and navigation.
///
/// Holds no profile state — `OnboardingModel` owns the draft and every step
/// binds into it.
struct OnboardingFlow: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var model: OnboardingModel

    init(user: User) {
        _model = StateObject(wrappedValue: OnboardingModel(user: user))
    }

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        titleBlock

                        stepContent
                            .id(model.draft.currentStep)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))

                        if let message = model.validationMessage {
                            ValidationMessage(message: message)
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.lg)
                    .padding(.bottom, Space.xxxl)
                }
                .scrollDismissesKeyboard(.interactively)

                footer
            }
        }
        .animation(Motion.transition, value: model.validationMessage)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Space.sm) {
            HStack {
                if model.currentIndex > 0 {
                    Button {
                        model.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: Size.iconMedium, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(width: Size.minTapTarget, height: Size.minTapTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Back")
                } else {
                    Color.clear.frame(width: Size.minTapTarget, height: Size.minTapTarget)
                }

                Spacer()

                Text("Step \(model.currentIndex + 1) of \(model.steps.count)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)

                Spacer()

                Color.clear.frame(width: Size.minTapTarget, height: Size.minTapTarget)
            }

            ProgressRail(progress: model.progress)
                .padding(.horizontal, Space.gutter)
        }
        .padding(.bottom, Space.sm)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(model.draft.currentStep.title)
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.draft.currentStep.subtitle)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(Typography.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch model.draft.currentStep {
        case .name: NameStep(model: model)
        case .dateOfBirth: DateOfBirthStep(model: model)
        case .gender: GenderStep(model: model)
        case .interestedIn: InterestedInStep(model: model)
        case .datingIntention: DatingIntentionStep(model: model)
        case .location: LocationStep(model: model)
        case .photos: PhotosStep(model: model)
        case .bio: BioStep(model: model)
        case .interests: InterestsStep(model: model)
        case .cameraAndMic: CameraMicStep(model: model)
        case .notifications: NotificationsStep(model: model)
        case .safety: SafetyStep(model: model)
        case .review: ReviewStep(model: model)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Space.sm) {
            PrimaryButton(
                title: model.isLastStep ? "Start meeting people" : "Continue",
                isEnabled: true,
                isLoading: model.isFinishing
            ) {
                if model.isLastStep {
                    Task { await model.finish(session: session) }
                } else {
                    model.advance()
                }
            }

            // Steps that are purely informational can be skipped; steps that
            // collect required data cannot.
            if model.draft.currentStep == .notifications {
                Button("Not now") { model.advance() }
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xs)
        .background(
            Palette.canvas
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: Palette.ink.opacity(0.04), radius: 12, y: -6)
        )
    }
}

/// Thin progress rail across the top of onboarding.
struct ProgressRail: View {
    var progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.separator)
                Capsule()
                    .fill(Palette.blue)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: 4)
        .animation(Motion.transition, value: progress)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}
