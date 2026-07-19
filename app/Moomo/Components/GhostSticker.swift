import SwiftUI

/// The little pink ghost that floats over the End Call button on the
/// speed-call screen.
///
/// Like `Mascot` and the logo, this is placeholder geometry approximating the
/// reference's illustration — the real character should arrive from the
/// designer as an asset.
struct GhostSticker: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack {
                GhostShape()
                    .fill(Palette.mascotPink)

                // Eyes
                HStack(spacing: w * 0.18) {
                    eye(diameter: w * 0.14)
                    eye(diameter: w * 0.14)
                }
                .position(x: w * 0.5, y: h * 0.42)

                // Open mouth
                Ellipse()
                    .fill(Palette.ink)
                    .frame(width: w * 0.14, height: w * 0.18)
                    .position(x: w * 0.5, y: h * 0.62)
            }
        }
        .accessibilityHidden(true)
    }

    private func eye(diameter: CGFloat) -> some View {
        Circle()
            .fill(Palette.ink)
            .frame(width: diameter, height: diameter)
    }
}

/// Dome head, straight sides, three-scallop wavy tail.
private struct GhostShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let sideBottom = h * 0.80

        path.move(to: CGPoint(x: 0, y: sideBottom))
        path.addLine(to: CGPoint(x: 0, y: h * 0.40))
        // Dome
        path.addCurve(
            to: CGPoint(x: w, y: h * 0.40),
            control1: CGPoint(x: 0, y: -h * 0.12),
            control2: CGPoint(x: w, y: -h * 0.12)
        )
        path.addLine(to: CGPoint(x: w, y: sideBottom))

        // Tail: alternating bumps, right to left.
        let scallop = w / 3
        for index in 0..<3 {
            let startX = w - CGFloat(index) * scallop
            let dip = index % 2 == 0 ? h : h * 0.66
            path.addQuadCurve(
                to: CGPoint(x: startX - scallop, y: sideBottom),
                control: CGPoint(x: startX - scallop / 2, y: dip)
            )
        }
        path.closeSubpath()
        return path
    }
}

#Preview {
    GhostSticker()
        .frame(width: 54, height: 60)
        .padding()
        .background(Palette.cream)
}
