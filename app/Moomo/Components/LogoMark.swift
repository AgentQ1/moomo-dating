import SwiftUI

/// The one place any screen may ask for the Moomo logo.
///
/// # Replacing the traced artwork
///
/// The figures inside `MoomoLogo` are hand-traced beziers approximating the
/// reference. They read correctly but are not the original artwork, and no
/// amount of further tracing will close that gap.
///
/// When the source vector arrives:
///
/// 1. Export the mark (figures **and** gold arc, no wordmark) as a PDF with
///    "Preserve Vector Data" enabled.
/// 2. Add it to `Assets.xcassets` as `LogoMark`, Scales: Single Scale,
///    Render As: Original.
/// 3. Flip `Self.source` to `.asset`.
///
/// That is the whole migration. No screen imports `MoomoLogo` directly, so no
/// layout code changes — every call site goes through `LogoMark`, which keeps
/// the same footprint either way.
struct LogoMark: View {
    /// Diameter of the enclosing gold arc. The mark is always square.
    var diameter: CGFloat = Size.logoDiameter

    /// Where the artwork comes from. Flip to `.asset` once the vector is in
    /// the catalog.
    private static let source: Source = .traced

    private enum Source {
        /// Hand-traced beziers. Temporary.
        case traced
        /// Designer-supplied vector in the asset catalog.
        case asset
    }

    var body: some View {
        Group {
            switch Self.source {
            case .traced:
                MoomoLogo(diameter: diameter)
            case .asset:
                Image("LogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: diameter, height: diameter)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Moomo")
    }
}

#Preview {
    ZStack {
        Palette.cream.ignoresSafeArea()
        LogoMark()
    }
}
