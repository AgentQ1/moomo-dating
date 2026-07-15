import SwiftUI

/// The four-point star that recurs across the references — scattered around the
/// logo, in the divider, between the decision avatars, above the call timer,
/// and as the active page indicator.
struct Sparkle: Shape {
    /// How pinched the waist is. Lower is thinner and more needle-like;
    /// the references sit around 0.3.
    var waist: CGFloat = 0.3

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let wx = rx * waist, wy = ry * waist

        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - ry))
        path.addQuadCurve(
            to: CGPoint(x: cx + rx, y: cy),
            control: CGPoint(x: cx + wx, y: cy - wy)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy + ry),
            control: CGPoint(x: cx + wx, y: cy + wy)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - rx, y: cy),
            control: CGPoint(x: cx - wx, y: cy + wy)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy - ry),
            control: CGPoint(x: cx - wx, y: cy - wy)
        )
        path.closeSubpath()
        return path
    }
}

/// A filled sparkle at a fixed size.
struct SparkleMark: View {
    var size: CGFloat
    var color: Color
    var waist: CGFloat = 0.3

    var body: some View {
        Sparkle(waist: waist)
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// The gold hairline-and-sparkle divider under the tagline on the welcome
/// screen: a rule that fades out at both ends with a sparkle centred on it.
struct SparkleDivider: View {
    /// ~0.27 × screen width in the reference.
    var width: CGFloat = 110

    var body: some View {
        HStack(spacing: Space.sm) {
            rule(fadingToward: .leading)
            SparkleMark(size: 9, color: Palette.gold)
            rule(fadingToward: .trailing)
        }
        .frame(width: width)
    }

    /// A hairline that is solid next to the sparkle and fades to nothing at the
    /// outer end.
    private func rule(fadingToward edge: UnitPoint) -> some View {
        LinearGradient(
            colors: [Palette.gold.opacity(0), Palette.gold.opacity(0.7)],
            startPoint: edge,
            endPoint: edge == .leading ? .trailing : .leading
        )
        .frame(height: 1)
    }
}

#Preview {
    ZStack {
        Palette.cream.ignoresSafeArea()
        VStack(spacing: 40) {
            SparkleMark(size: 22, color: Palette.blue)
            SparkleDivider()
        }
    }
}
