import SwiftUI

/// Boost state and activation.
@MainActor
final class BoostModel: ObservableObject {
    @Published private(set) var state = BoostState(activeUntil: nil, remainingBoosts: 0)
    @Published private(set) var isActivating = false
    @Published var failureMessage: String?

    private let service: BoostService
    private var observationTask: Task<Void, Never>?

    init(service: BoostService) {
        self.service = service
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await state in service.stateStream {
                guard !Task.isCancelled else { return }
                self.state = state
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    func activate() async {
        guard !isActivating else { return }
        isActivating = true
        defer { isActivating = false }
        do {
            _ = try await service.activate()
            failureMessage = nil
        } catch {
            failureMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't start the boost. Please try again."
        }
    }
}

/// Presented as a sheet from Discover's Boost button.
///
/// Boosts are free during the beta and the copy says so — there is no
/// StoreKit yet, and nothing here may imply payment until there is.
struct BoostView: View {
    @ObservedObject var model: BoostModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.md) {
                    ZStack {
                        Circle()
                            .fill(Palette.premiumCream)
                            .frame(width: 110, height: 110)
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Palette.gold)
                    }
                    .padding(.top, Space.xl)
                    .accessibilityHidden(true)

                    Text(model.state.isActive() ? "You're boosted!" : "Boost your profile")
                        .font(Typography.heroTitle)
                        .foregroundStyle(Palette.ink)

                    Text(model.state.isActive()
                         ? "You're at the front of the matchmaking queue. Answer when someone calls!"
                         : "Jump to the front of the matchmaking queue for 30 minutes, so more people meet you first.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Space.lg)

                    if model.state.isActive(), let until = model.state.activeUntil {
                        Label(
                            "Active until \(until.formatted(date: .omitted, time: .shortened))",
                            systemImage: "clock.fill"
                        )
                        .font(Typography.rowTitleSmall)
                        .foregroundStyle(Palette.verifiedGreenFG)
                        .padding(.horizontal, Space.md)
                        .padding(.vertical, Space.xs)
                        .background(Capsule().fill(Palette.verifiedGreenBG))
                        .accessibilityIdentifier("boost.activeUntil")
                    }

                    if let failure = model.failureMessage {
                        ValidationMessage(message: failure)
                            .padding(.horizontal, Space.lg)
                    }

                    if !model.state.isActive() {
                        PrimaryButton(
                            title: "Boost now",
                            icon: "bolt.fill",
                            isEnabled: model.state.remainingBoosts > 0,
                            isLoading: model.isActivating
                        ) {
                            Task { await model.activate() }
                        }
                        .padding(.horizontal, Space.xl)
                        .padding(.top, Space.sm)
                        .accessibilityIdentifier("boost.activate")
                    }

                    Text(model.state.remainingBoosts == 1
                         ? "1 boost left — refreshed daily."
                         : "\(model.state.remainingBoosts) boosts left — refreshed daily.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.bottom, Space.xl)
                }
                .frame(maxWidth: .infinity)
            }
            .background(Palette.canvas)
            .navigationTitle("Boost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
