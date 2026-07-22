import SwiftUI

/// The Moomo brand mark: a gold arc enclosing two figures — rose on the left,
/// navy on the right — whose bodies form the outer legs of an "M" and whose
/// clasped arms form its middle V, with the serif wordmark beneath.
///
/// The figures are hand-traced beziers from the reference screen. They are a
/// close approximation, not the original artwork. If the source vector exists
/// (Illustrator/SVG/PDF), drop it into the asset catalog as a template PDF and
/// swap `MFigures` for an `Image` — that is the only way to reach true parity.
struct MoomoLogo: View {
    var diameter: CGFloat = Size.logoDiameter

    var body: some View {
        ZStack {
            GoldArc()
                .stroke(
                    Palette.goldArc,
                    style: StrokeStyle(lineWidth: diameter * 0.0145, lineCap: .round)
                )
                .frame(width: diameter, height: diameter)

            // Both elements are placed from the arc's centre using offsets
            // measured off the reference, rather than stacked — the reference
            // spacing between the figures and the wordmark isn't a constant, it
            // is a consequence of where each sits inside the ring.
            //
            // The figures span 0.70 × their box horizontally and 0.935
            // vertically, so the frame is grossed up on each axis independently
            // to land the artwork at the 0.46 × 0.468 it occupies in the
            // reference. That squashes the traced paths slightly, which is
            // correct: the reference figures are stockier than a naive trace.
            MFigures()
                .frame(width: diameter * 0.657, height: diameter * 0.50)
                .offset(y: -diameter * 0.032)

            Text("baybe")
                .font(Typography.wordmark(size: diameter * 0.13))
                .foregroundStyle(Palette.gold)
                .tracking(diameter * 0.004)
                .offset(y: diameter * 0.266)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("Baybe")
    }
}

/// The enclosing ring. Not a closed circle — it opens at the upper right, the
/// gap running from roughly 12:30 to 2:30 with the lone gold sparkle sitting
/// in the opening. Measured off the reference: the upper terminal is at about
/// -78° and the lower one at about -13° (0° = 3 o'clock, clockwise positive).
private struct GoldArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: .degrees(-13),
            endAngle: .degrees(282),
            clockwise: false
        )
        return path
    }
}

/// The two figures. Drawn in a unit square and scaled, so the geometry is
/// resolution-independent.
private struct MFigures: View {
    var body: some View {
        ZStack {
            RoseFigure()
                .fill(Palette.rose)

            NavyFigure()
                .fill(Palette.blue)
        }
    }
}

/// Left figure — head plus a body that sweeps down-left into the M's left leg,
/// with an arm reaching down-right to the clasp at centre.
private struct RoseFigure: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }

        var path = Path()

        // Head. Sized from the width on both axes so it stays a true circle —
        // the frame this is drawn into is deliberately not square, and keying
        // the height off `h` would render it as an ellipse.
        let head = 0.190 * w
        path.addEllipse(in: CGRect(
            x: rect.minX + 0.205 * w,
            y: rect.minY + 0.045 * h,
            width: head,
            height: head
        ))

        // Body + arm
        path.move(to: p(0.212, 0.290))
        // Outer-left edge, shoulder down to the foot of the left leg.
        path.addCurve(to: p(0.150, 0.965), control1: p(0.155, 0.470), control2: p(0.128, 0.790))
        // Foot.
        path.addCurve(to: p(0.318, 0.965), control1: p(0.185, 1.000), control2: p(0.285, 1.000))
        // Inner edge of the leg, rising toward the clasp.
        path.addCurve(to: p(0.492, 0.628), control1: p(0.345, 0.812), control2: p(0.432, 0.706))
        // Hand.
        path.addCurve(to: p(0.498, 0.548), control1: p(0.523, 0.606), control2: p(0.523, 0.566))
        // Top edge of the arm, back up to the shoulder.
        path.addCurve(to: p(0.352, 0.292), control1: p(0.430, 0.520), control2: p(0.392, 0.372))
        path.closeSubpath()

        return path
    }
}

/// Right figure — mirror of the rose figure across the vertical centre line.
private struct NavyFigure: Shape {
    func path(in rect: CGRect) -> Path {
        let mirrored = RoseFigure().path(in: rect)
        return mirrored.applying(
            CGAffineTransform(translationX: rect.width + 2 * rect.minX, y: 0)
                .scaledBy(x: -1, y: 1)
        )
    }
}

#Preview("Logo") {
    ZStack {
        Palette.cream.ignoresSafeArea()
        MoomoLogo()
    }
}
