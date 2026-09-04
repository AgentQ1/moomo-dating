import SwiftUI

/// Welcome / sign-in — the app's first screen. Phone OTP is the only way in:
/// enter a number, receive an SMS code, type it, signed in.
///
/// The screen is a reproduction of `tools/visual/reference/welcome.png`, and
/// it is built by placing blocks at the coordinates measured off that file
/// (`WelcomeMetrics`) rather than by stacking paddings. Two reasons: the
/// reference is a design export whose vertical rhythm does not fall out of any
/// natural SwiftUI spacing, and a coordinate is independently correctable —
/// nudging the CTA cannot drag the consent sentence with it.
///
/// Everything is drawn live. The one bitmap that is not a photograph is the
/// skyline band, which is genuine artwork with no vector source available; the
/// rest — sketches, rules, capsule, checkbox, pager — are shapes.
///
/// The button renders at full strength before consent — as the reference
/// shows — and validates the checkbox on tap instead.
struct WelcomeView: View {
    @StateObject private var phone: PhoneAuthModel

    @State private var hasConsented = false
    @State private var legalDocument: LegalDocument?
    @State private var isShowingLoginHelp = false
    @FocusState private var isPhoneFocused: Bool

    init(auth: AuthenticationService) {
        _phone = StateObject(wrappedValue: PhoneAuthModel(auth: auth))
    }

    var body: some View {
        GeometryReader { proxy in
            // Absolute display coordinates, converted into this proxy's own
            // space. `minY` in global space is where this reader actually
            // begins on the display — the safe-area top in a normal launch,
            // and lower when the debug build stacks its mock-mode banner above
            // the routed screen. Subtracting it keeps every measured `y`
            // meaning on screen exactly what it means in the reference.
            let originY = proxy.frame(in: .global).minY

            // Overlays rather than a `ZStack`, deliberately. A stack sizes
            // itself to the union of its children, so a block placed by its
            // text baseline — which reaches above the stack's top edge by the
            // font's ascent — grows the stack upward and pushes every other
            // block down with it. An overlay never resizes what it is drawn
            // on, so each coordinate below means exactly what it says.
            Color.clear
                .overlay(alignment: .topLeading) {
                    skyline(originY: originY, width: proxy.size.width)
                }
                .overlay(alignment: .topLeading) { sketches(originY: originY) }
                .overlay(alignment: .top) {
                    helpLink.place(firstBaseline: WelcomeMetrics.helpLinkBaseline, in: originY)
                }
                .overlay(alignment: .top) {
                    avatarCluster.place(top: avatarClusterTop, in: originY)
                }
                .overlay(alignment: .top) {
                    headlineLine("Find the person nearby")
                        .place(firstBaseline: WelcomeMetrics.headlineFirstBaseline, in: originY)
                }
                .overlay(alignment: .top) {
                    headlineLine("you\u{2019}d most like to meet")
                        .place(firstBaseline: WelcomeMetrics.headlineSecondBaseline, in: originY)
                }
                .overlay(alignment: .top) {
                    phoneRow.place(top: WelcomeMetrics.phoneRowTop, in: originY)
                }
                .overlay(alignment: .top) {
                    hairline.place(top: WelcomeMetrics.hairlineCentreY - 0.5, in: originY)
                }
                .overlay(alignment: .top) {
                    errorLine.place(top: WelcomeMetrics.errorTop, in: originY)
                }
                .overlay(alignment: .top) {
                    verificationButton.place(top: WelcomeMetrics.ctaTop, in: originY)
                }
                .overlay(alignment: .top) {
                    consent.place(firstBaseline: WelcomeMetrics.consentFirstBaseline, in: originY)
                }
                .overlay(alignment: .top) {
                    pager.place(top: pagerTop, in: originY)
                }
        }
        .background(Palette.blush.ignoresSafeArea())
        .sheet(item: $legalDocument) { document in
            LegalDocumentView(document: document)
        }
        .fullScreenCover(isPresented: showingOTP) {
            OTPEntryView(model: phone)
        }
        .alert("Trouble logging in?", isPresented: $isShowingLoginHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Make sure you can receive SMS at your number. Still stuck? Email moomolab@gmail.com.")
        }
        .onDisappear { phone.cancel() }
        .animation(Motion.transition, value: phone.error)
    }

    /// The OTP screen is up from the moment the SMS is out until sign-in
    /// succeeds (routing then replaces this screen entirely) or the user
    /// backs out to edit the number.
    private var showingOTP: Binding<Bool> {
        Binding(
            get: { phone.stage == .codeSent || phone.stage == .verifying },
            set: { if !$0 { phone.editNumber() } }
        )
    }

    // MARK: - Derived tops
    //
    // The reference gives a centre line for these; SwiftUI wants the frame's
    // top edge. Text blocks are placed by their first baseline instead, which
    // needs no such conversion.

    private var avatarClusterTop: CGFloat {
        WelcomeMetrics.avatarCentreY - WelcomeMetrics.avatarOuter / 2
    }

    private var pagerTop: CGFloat {
        WelcomeMetrics.pagerCentreY - WelcomeMetrics.pagerActiveDiagonal / 2
    }

    // MARK: - Top bar

    private var helpLink: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button("Trouble logging in?") {
                isShowingLoginHelp = true
            }
            .font(Typography.welcomeHelpLink)
            .foregroundStyle(Palette.welcomeInk)
            .buttonStyle(.plain)
        }
        .padding(.trailing, WelcomeMetrics.helpLinkTrailing)
    }

    // MARK: - Avatars

    /// Four overlapping circles. The reference's stacking is not a simple
    /// left-over-right cascade: each circle covers the one to its left, but
    /// the third also covers the fourth, so the ring that reads on top at the
    /// third/fourth seam belongs to the third. Drawing order below is exactly
    /// that — 1, 2, 4, then 3 last.
    private var avatarCluster: some View {
        let step = WelcomeMetrics.avatarSpacing
        let crops = WelcomeMetrics.avatarCrops
        return ZStack {
            avatar(crops[0]).offset(x: -1.5 * step)
            avatar(crops[1]).offset(x: -0.5 * step)
            avatar(crops[3]).offset(x: 1.5 * step)
            avatar(crops[2]).offset(x: 0.5 * step)
        }
        .frame(height: WelcomeMetrics.avatarOuter)
        .accessibilityHidden(true)
    }

    private func avatar(_ crop: WelcomeMetrics.AvatarCrop) -> some View {
        let photo = WelcomeMetrics.avatarPhoto
        return Color.clear
            .frame(width: photo, height: photo)
            .overlay(
                Image(crop.asset)
                    .resizable()
                    .scaledToFill()
                    .frame(width: photo * crop.zoom, height: photo * crop.zoom)
                    .offset(crop.shift)
            )
            .clipShape(Circle())
            // The ring sits outside the photograph, not over it — the
            // reference's visible photo is the full inner circle.
            .padding(WelcomeMetrics.avatarRing)
            .background(Circle().fill(.white))
            .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
    }

    // MARK: - Headline

    /// One line, placed on its own measured baseline. Two `Text`s rather than
    /// one wrapping block, because the reference's two baselines sit closer
    /// together than this face's natural line height and pinning each is
    /// exact where fighting `lineSpacing` is not.
    private func headlineLine(_ text: String) -> some View {
        Text(text)
            .font(Typography.welcomeHeadline)
            .foregroundStyle(Palette.welcomeInk)
            .fixedSize()
            .frame(maxWidth: .infinity)
    }

    // MARK: - Phone entry

    private var phoneRow: some View {
        PhoneEntryRow(model: phone, isFocused: $isPhoneFocused)
            .frame(height: WelcomeMetrics.phoneRowHeight)
            .padding(.horizontal, WelcomeMetrics.fieldInset)
            .offset(x: WelcomeMetrics.phoneRowX)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Palette.welcomeHairline)
            .frame(height: 1)
            .padding(.horizontal, WelcomeMetrics.fieldInset)
    }

    /// Sits in the gap between the rule and the CTA, which is empty in the
    /// reference — nothing moves when a message appears.
    private var errorLine: some View {
        PhoneFlowErrorText(error: phone.error)
            .padding(.horizontal, WelcomeMetrics.fieldInset)
    }

    private var verificationButton: some View {
        VerificationButton(isLoading: phone.stage == .sendingCode) {
            isPhoneFocused = false
            phone.sendCode(hasConsented: hasConsented)
        }
        .padding(.horizontal, WelcomeMetrics.fieldInset)
    }

    // MARK: - Consent

    private var consent: some View {
        ConsentRow(
            isChecked: $hasConsented,
            onOpenPrivacy: { legalDocument = .privacy },
            onOpenTerms: { legalDocument = .terms }
        )
    }

    // MARK: - Pager

    private var pager: some View {
        PageDots(
            count: WelcomeMetrics.pagerCount,
            activeIndex: WelcomeMetrics.pagerActiveIndex
        )
    }

    // MARK: - Background

    /// The Chicago skyline band. Full-bleed across, and clear of the home
    /// indicator by the margin the reference leaves.
    private func skyline(originY: CGFloat, width: CGFloat) -> some View {
        // Stretched to the band exactly, not aspect-fitted. The reference is
        // itself a hair taller than wide relative to a device, and the artwork
        // was cut from it — letting the image keep its own aspect would crop
        // the ends off the skyline instead of reproducing that band.
        Image("welcome-skyline")
            .resizable()
            .frame(width: width, height: WelcomeMetrics.skylineHeight)
            .offset(y: WelcomeMetrics.skylineTop - originY)
            .accessibilityHidden(true)
    }

    /// The faint outlined marks over the blush. Decorative only.
    private func sketches(originY: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            SketchTriangle()
                .stroke(
                    Palette.welcomeSketch,
                    style: StrokeStyle(
                        lineWidth: WelcomeMetrics.sketchTriangleStroke,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(
                    width: WelcomeMetrics.sketchTriangleRadius * 2,
                    height: WelcomeMetrics.sketchTriangleRadius * 2
                )
                .rotationEffect(WelcomeMetrics.sketchTriangleRotation)
                .centred(
                    on: WelcomeMetrics.sketchTriangleCentre,
                    size: WelcomeMetrics.sketchTriangleRadius * 2,
                    in: originY
                )

            SketchCross()
                .stroke(
                    Palette.welcomeSketch,
                    style: StrokeStyle(lineWidth: WelcomeMetrics.sketchCrossStroke, lineCap: .butt)
                )
                .frame(width: WelcomeMetrics.sketchCrossSize, height: WelcomeMetrics.sketchCrossSize)
                .centred(
                    on: WelcomeMetrics.sketchCrossCentre,
                    size: WelcomeMetrics.sketchCrossSize,
                    in: originY
                )

            sparkle.centred(
                on: WelcomeMetrics.sketchSparkleLeftCentre,
                size: WelcomeMetrics.sketchSparkleSize,
                in: originY
            )
            sparkle.centred(
                on: WelcomeMetrics.sketchSparkleRightCentre,
                size: WelcomeMetrics.sketchSparkleSize,
                in: originY
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var sparkle: some View {
        SketchSparkle()
            .fill(Palette.welcomeSketch)
            .frame(width: WelcomeMetrics.sketchSparkleSize, height: WelcomeMetrics.sketchSparkleSize)
    }
}

// MARK: - Placement

private extension View {
    /// Pin this view's top edge to an absolute display coordinate, given the
    /// safe-area origin the enclosing reader starts at.
    func place(top: CGFloat, in originY: CGFloat) -> some View {
        frame(maxWidth: .infinity)
            .offset(y: top - originY)
    }

    /// Pin this view's first text baseline to an absolute display coordinate.
    /// The reference gives baselines, not frame tops, and reading one off a
    /// glyph's ink is exact where reconstructing a frame from font metrics is
    /// a guess about how SwiftUI distributes leading.
    func place(firstBaseline y: CGFloat, in originY: CGFloat) -> some View {
        frame(maxWidth: .infinity)
            .alignmentGuide(.top) { $0[.firstTextBaseline] }
            .offset(y: y - originY)
    }

    /// Pin a known-size square's centre to an absolute display coordinate.
    /// Offsets only — an alignment guide here would grow the enclosing stack
    /// by the overhang and drag its siblings along.
    func centred(on point: CGPoint, size: CGFloat, in originY: CGFloat) -> some View {
        offset(x: point.x - size / 2, y: point.y - size / 2 - originY)
    }
}

// MARK: - Sketches

/// The outlined triangle top-left of the avatars: equilateral, corners
/// rounded by the stroke's own round join.
struct SketchTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<3 {
            let angle = Angle.degrees(Double(index) * 120)
            let point = CGPoint(
                x: centre.x + radius * CGFloat(cos(angle.radians)),
                y: centre.y + radius * CGFloat(sin(angle.radians))
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// The thin cross to the right of the avatars.
struct SketchCross: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// A four-point sparkle — a diamond with its edges pulled in toward the
/// centre, as the reference draws it.
struct SketchSparkle: Shape {
    /// Waist controls sit out along the diagonals rather than at the centre.
    /// Pinned to the centre the arms taper to nothing and antialiasing eats
    /// the points, which measured 2pt short of the reference's.
    private static let waist: CGFloat = 0.30

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let rx = rect.width / 2, ry = rect.height / 2
        let wx = rx * Self.waist, wy = ry * Self.waist
        let top = CGPoint(x: cx, y: rect.minY)
        let right = CGPoint(x: rect.maxX, y: cy)
        let bottom = CGPoint(x: cx, y: rect.maxY)
        let left = CGPoint(x: rect.minX, y: cy)
        var path = Path()
        path.move(to: top)
        path.addQuadCurve(to: right, control: CGPoint(x: cx + wx, y: cy - wy))
        path.addQuadCurve(to: bottom, control: CGPoint(x: cx + wx, y: cy + wy))
        path.addQuadCurve(to: left, control: CGPoint(x: cx - wx, y: cy + wy))
        path.addQuadCurve(to: top, control: CGPoint(x: cx - wx, y: cy - wy))
        path.closeSubpath()
        return path
    }
}

// MARK: - Pager

/// Page indicator. Six grey dots and one magenta diamond, laid out in
/// fixed-width cells so the wider active mark keeps the pitch even.
struct PageDots: View {
    var count: Int
    var activeIndex: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Group {
                    if index == activeIndex {
                        RoundedRectangle(
                            cornerRadius: WelcomeMetrics.pagerActiveCornerRadius,
                            style: .continuous
                        )
                            .fill(Palette.verificationMagenta)
                            .frame(
                                width: WelcomeMetrics.pagerActiveDiagonal / sqrt(2),
                                height: WelcomeMetrics.pagerActiveDiagonal / sqrt(2)
                            )
                            .rotationEffect(.degrees(45))
                    } else {
                        Circle()
                            .fill(Palette.welcomeDotInactive)
                            .frame(
                                width: WelcomeMetrics.pagerDotDiameter,
                                height: WelcomeMetrics.pagerDotDiameter
                            )
                    }
                }
                .frame(width: WelcomeMetrics.pagerPitch)
            }
        }
        .frame(height: WelcomeMetrics.pagerActiveDiagonal)
        .accessibilityHidden(true)
    }
}

#Preview {
    WelcomeView(auth: MockAuthenticationService())
}
