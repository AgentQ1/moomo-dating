import SwiftUI

/// The white pill above the Discover hero: the two filters that decide who
/// Discover shows you.
///
/// Two halves, two destinations. Left is where you're browsing; right is what
/// you're here for. They used to open the same city picker, which made the
/// divider a lie — the right half now carries the dating intention, which is a
/// real matching filter (`MatchPreferences.areIntentionsCompatible`).
struct DiscoverLocationBar: View {
    /// "Chicago, IL", or the prompt shown when no city is set yet.
    var title: String
    /// The chosen intention, or nil to show the "set one" prompt.
    var intention: DatingIntention?
    var onOpenLocation: () -> Void
    var onOpenIntention: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpenLocation) {
                HStack(spacing: Space.xs) {
                    MapPinMark()
                        .frame(width: 19, height: 23)
                        .foregroundStyle(Palette.ink)

                    Text(title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.ink)

                    Spacer(minLength: Space.xs)
                }
                .padding(.horizontal, Space.md)
                .frame(maxWidth: .infinity, minHeight: Size.locationBarHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Browsing near \(title). Change location")
            .accessibilityIdentifier("discover.locationBar")

            Rectangle()
                .fill(Palette.separator)
                .frame(width: 1, height: 26)

            Button(action: onOpenIntention) {
                HStack(spacing: Space.xs) {
                    Image(systemName: intention == nil ? "heart" : "heart.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(intention == nil ? Palette.ink : Palette.magenta)
                    Text(intention?.compactLabel ?? "Intent")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .padding(.horizontal, Space.md)
                .frame(minHeight: Size.locationBarHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The city can shrink; the intention should not be squeezed out of
            // existence by a long one.
            .layoutPriority(1)
            .accessibilityLabel(
                intention.map { "Looking for: \($0.label). Change" }
                    ?? "Set what you're looking for"
            )
            .accessibilityIdentifier("discover.intention")
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .shadow(Shadows.card)
    }
}

#Preview {
    VStack(spacing: Space.md) {
        DiscoverLocationBar(
            title: "Chicago, IL", intention: .longTerm,
            onOpenLocation: {}, onOpenIntention: {}
        )
        DiscoverLocationBar(
            title: "Chicago, IL", intention: nil,
            onOpenLocation: {}, onOpenIntention: {}
        )
        DiscoverLocationBar(
            title: "San Francisco, CA", intention: .figuringItOut,
            onOpenLocation: {}, onOpenIntention: {}
        )
    }
    .padding(Space.gutter)
    .background(Palette.canvas)
}
