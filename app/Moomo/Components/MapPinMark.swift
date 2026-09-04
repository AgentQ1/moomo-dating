import SwiftUI

/// The teardrop map marker: a circular head with a tail falling to a point at
/// the bottom centre.
///
/// Drawn rather than taken from SF Symbols — `mappin` is a needle pin and
/// `mappin.and.ellipse` sits on a shadow ellipse, and neither is the plain
/// teardrop the Discover reference uses.
struct MapPinShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.width / 2
        let centre = CGPoint(x: rect.midX, y: rect.minY + radius)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: centre.y))
        path.addArc(
            center: centre,
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.minX + rect.width * 0.92, y: rect.minY + rect.height * 0.62)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: centre.y),
            control: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.62)
        )
        path.closeSubpath()
        return path
    }
}

/// The hollow outline form of `MapPinShape`, with the hole in its head.
struct MapPinMark: View {
    var lineWidth: CGFloat = 1.8

    var body: some View {
        GeometryReader { proxy in
            let radius = proxy.size.width / 2
            ZStack {
                MapPinShape()
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
                Circle()
                    .stroke(lineWidth: lineWidth)
                    .frame(width: radius * 0.78, height: radius * 0.78)
                    .position(x: radius, y: radius)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: Space.lg) {
        MapPinMark()
            .frame(width: 19, height: 23)
            .foregroundStyle(Palette.ink)
        MapPinShape()
            .fill(Palette.magenta)
            .frame(width: 30, height: 38)
    }
    .padding()
    .background(Palette.canvas)
}
