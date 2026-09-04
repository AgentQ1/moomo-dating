import SwiftUI

/// Primary action button. The coral pill from the auth reference, reused as
/// the app's main CTA.
struct PrimaryButton: View {
    var title: String
    var icon: String?
    var isEnabled: Bool = true
    var isLoading: Bool = false
    /// Pill colour. Coral everywhere except the Discover hero, whose reference
    /// uses the deeper magenta.
    var fill: Color = Palette.coral
    var action: () -> Void

    @State private var isPressed = false
    private var isInteractive: Bool { isEnabled && !isLoading }

    /// The tinted CTA lift, keyed to whatever the pill is filled with — a
    /// coral-tinted shadow under a magenta pill reads as a printing error.
    private var lift: ShadowStyle {
        ShadowStyle(color: fill.opacity(0.32), radius: 18, x: 0, y: 8)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: Size.iconMedium, weight: .semibold))
                    }
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Size.primaryCTAHeight)
            .background(Capsule().fill(fill))
            .shadow(isEnabled ? lift : Shadows.card)
            .scaleEffect(isPressed ? Motion.pressedScale : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .saturation(isEnabled ? 1 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .animation(Motion.tap, value: isPressed)
        .animation(Motion.transition, value: isEnabled)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isInteractive { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityValue(isLoading ? "Loading" : "")
    }
}

/// A single-line text field styled as a card, matching the chat input bar's
/// treatment from the reference.
struct MoomoTextField: View {
    var placeholder: String
    @Binding var text: String
    var characterLimit: Int?

    var body: some View {
        HStack {
            TextField(placeholder, text: $text)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
                .onChange(of: text) { _, newValue in
                    if let characterLimit, newValue.count > characterLimit {
                        text = String(newValue.prefix(characterLimit))
                    }
                }
        }
        .padding(.horizontal, Space.md)
        .frame(height: Size.inputBarHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .shadow(Shadows.card)
    }
}

/// Multi-line text entry with a live character count.
struct MoomoTextEditor: View {
    var placeholder: String
    @Binding var text: String
    var characterLimit: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Typography.message)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.top, Space.sm)
                        .padding(.horizontal, Space.md)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(Typography.message)
                    .foregroundStyle(Palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, Space.sm)
                    .padding(.top, Space.xxs)
                    .onChange(of: text) { _, newValue in
                        if newValue.count > characterLimit {
                            text = String(newValue.prefix(characterLimit))
                        }
                    }
            }
            .frame(height: 140)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.surface)
            )
            .shadow(Shadows.card)

            Text("\(text.count)/\(characterLimit)")
                .font(Typography.caption)
                .foregroundStyle(
                    text.count >= characterLimit ? Palette.coral : Palette.textTertiary
                )
                .accessibilityLabel("\(text.count) of \(characterLimit) characters used")
        }
    }
}

/// A selectable option card. Used for gender, interested-in, and any other
/// pick-one/pick-many step.
struct SelectableCard: View {
    var title: String
    var subtitle: String?
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.cardTitle)
                        .foregroundStyle(isSelected ? Palette.blue : Palette.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Size.iconLarge))
                        .foregroundStyle(Palette.blue)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, Space.md)
            .frame(minHeight: Size.decisionCardHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(isSelected ? Palette.blueTint : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(isSelected ? Palette.blue : .clear, lineWidth: 1.5)
            )
            .shadow(Shadows.card)
        }
        .buttonStyle(.plain)
        .animation(Motion.tap, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A chip for multi-select lists (interests).
struct InterestChip: View {
    var label: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Typography.rowTitle)
                .foregroundStyle(isSelected ? .white : Palette.textPrimary)
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
                .background(
                    Capsule().fill(isSelected ? Palette.blue : Palette.surface)
                )
                .overlay(
                    Capsule().stroke(isSelected ? .clear : Palette.separator, lineWidth: 1)
                )
                .shadow(Shadows.card)
        }
        .buttonStyle(.plain)
        .animation(Motion.tap, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Inline validation message.
struct ValidationMessage: View {
    var message: String

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: Size.iconSmall))
            Text(message)
                .font(Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.coral)
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Banner shown whenever the app is running without a real backend, so a mock
/// session can never be mistaken for a real one.
struct MockModeBanner: View {
    var reason: BackendConfiguration.MockReason

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("LOCAL MOCK MODE — \(reason.explanation)")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Palette.ink.opacity(0.92))
        .accessibilityLabel("Local mock mode. \(reason.explanation). Data is not saved to a server.")
    }
}
