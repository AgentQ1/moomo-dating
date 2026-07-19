import SwiftUI

// MARK: - Chat modes

/// One of the two mode tiles under the hero ("Video Match", "Real Talk").
struct ChatModeTile: View {
    var title: String
    var subtitle: String
    var icon: String
    var iconColor: Color
    var gradient: LinearGradient
    var mascotColor: Color
    var action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.ink)

                Text(subtitle)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xxs)

                Spacer(minLength: Space.sm)

                ZStack {
                    Circle()
                        .fill(.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Size.chatModeTileHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(gradient)
            )
            .overlay(alignment: .bottomTrailing) {
                Mascot(color: mascotColor)
                    .frame(width: 92, height: 92)
                    .padding(.trailing, -6)
                    .padding(.bottom, -4)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .shadow(Shadows.card)
            .scaleEffect(isPressed ? Motion.pressedScale : 1)
        }
        .buttonStyle(.plain)
        .animation(Motion.tap, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

/// The blob mascot in the corner of each chat-mode tile.
///
/// Placeholder geometry approximating the reference's character. Like the
/// logo, these are illustrations that should come from the designer as assets
/// rather than be drawn in code.
private struct Mascot: View {
    var color: Color

    var body: some View {
        ZStack {
            Ellipse()
                .fill(color)
                .frame(width: 66, height: 74)
                .offset(y: 8)

            // Eyes
            HStack(spacing: 12) {
                eye
                eye
            }
            .offset(y: -4)

            // Arms
            Capsule()
                .fill(color)
                .frame(width: 26, height: 13)
                .rotationEffect(.degrees(24))
                .offset(x: -34, y: 20)
        }
    }

    private var eye: some View {
        ZStack {
            Circle().fill(Palette.ink).frame(width: 9, height: 9)
            Circle().fill(.white).frame(width: 3, height: 3).offset(x: 1, y: -1.5)
        }
    }
}
