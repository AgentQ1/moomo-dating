import SwiftUI

/// One action revealed behind a swiped row.
struct SwipeRowAction: Identifiable {
    var title: String
    var icon: String
    var tint: Color
    var foreground: Color = .white
    var handler: () -> Void

    var id: String { title }
}

/// Swipe-left actions over any row content: drag left to reveal full-height
/// action buttons, tap one to act, tap the row or swipe back to close.
///
/// Custom rather than `.swipeActions` because the app's lists are
/// `ScrollView` + `VStack` cards (the design system's rounded white cards
/// can't be built from `List`).
///
/// The drag MUST be attached with `simultaneousGesture`, not `.gesture`:
/// inside a `ScrollView`, the scroll pan claims the touch stream exclusively
/// as soon as movement passes its own threshold, and a plain `.gesture` on
/// row content (which is itself a `Button`, adding its own recognizers)
/// loses that arbitration and simply never fires. Simultaneous recognition
/// opts out of the exclusivity; the per-gesture axis lock below then keeps
/// vertical scrolls from dragging rows sideways.
struct SwipeActionsRow<Content: View>: View {
    var id: String
    var actions: [SwipeRowAction]
    /// The one open row in the list, shared by every row so opening one
    /// closes the rest.
    @Binding var openRowID: String?
    /// The row's tap action (open the conversation). Owned HERE, as a
    /// `TapGesture`, and not by a `Button` inside `content`: a SwiftUI
    /// Button fires on touch-up-inside even after a long drag, so a
    /// swipe-open would ALSO navigate. A tap gesture fails the moment the
    /// finger travels, which is exactly the difference this row needs.
    var onTap: (() -> Void)?
    @ViewBuilder var content: Content

    /// Live drag state. `@GestureState`, not `@State`, on purpose: a gesture
    /// the system cancels (incoming call, app backgrounded mid-swipe) never
    /// reaches `onEnded`, and plain state would leave the row frozen
    /// half-open with a stale axis lock. `@GestureState` resets itself on
    /// end AND cancel.
    @GestureState(resetTransaction: Transaction(animation: Motion.tap))
    private var progress = DragProgress()

    /// What this finger is doing, decided once at first movement and held
    /// until it lifts. Without the lock, a vertical scroll that drifts
    /// sideways mid-flight would start dragging rows.
    private enum DragAxis { case undecided, horizontal, vertical }

    private struct DragProgress {
        var axis: DragAxis = .undecided
        var translation: CGFloat = 0
    }

    private static var actionWidth: CGFloat { 76 }
    private var actionsWidth: CGFloat { CGFloat(actions.count) * Self.actionWidth }
    private var isOpen: Bool { openRowID == id }

    private var offset: CGFloat {
        let base: CGFloat = isOpen ? -actionsWidth : 0
        // Clamp: never right of rest, and rubber-stop just past fully open.
        return min(0, max(base + progress.translation, -actionsWidth - Space.md))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Invisible until the row is actually displaced: at rest the
            // buttons sit behind the content, and a section expand/collapse
            // fade would otherwise show them through the semi-transparent row.
            actionButtons
                .opacity(offset < 0 ? 1 : 0)
                .allowsHitTesting(offset < 0)

            content
                .background(Palette.surface)
                .contentShape(Rectangle())
                .onTapGesture {
                    // An open row's first tap closes it instead of navigating.
                    if isOpen {
                        close()
                    } else {
                        onTap?()
                    }
                }
                .offset(x: offset)
        }
        .clipped()
        // Flattened so transition fades apply to the composited row: without
        // this, a fading row and the buttons behind it fade independently and
        // the buttons bleed through the semi-transparent surface.
        .compositingGroup()
        .simultaneousGesture(drag)
        .animation(Motion.tap, value: openRowID)
        .accessibilityElement(children: .contain)
        // Swipe gestures are invisible to VoiceOver; expose each action.
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title) { action.handler() }
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($progress) { value, state, _ in
                if state.axis == .undecided {
                    state.axis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal
                        : .vertical
                }
                guard state.axis == .horizontal else { return }
                state.translation = value.translation.width
            }
            .onEnded { value in
                // The @GestureState lock has already reset by now; re-derive
                // dominance from the finished drag. A gesture that scrolled
                // the list is vertical-dominant and changes nothing here.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // Predicted end so a quick flick opens without needing to be
                // dragged the full distance, like a UIKit swipe cell.
                let projected = (isOpen ? -actionsWidth : 0) + value.predictedEndTranslation.width
                withAnimation(Motion.tap) {
                    if projected < -actionsWidth / 2 {
                        openRowID = id
                    } else if isOpen {
                        openRowID = nil
                    }
                }
            }
    }

    private var actionButtons: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    close()
                    action.handler()
                } label: {
                    VStack(spacing: Space.xxs) {
                        Image(systemName: action.icon)
                            .font(.system(size: Size.iconMedium, weight: .semibold))
                        Text(action.title)
                            .font(Typography.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(action.foreground)
                    .frame(width: Self.actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(action.tint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.title)
            }
        }
    }

    private func close() {
        withAnimation(Motion.tap) {
            openRowID = nil
        }
    }
}
