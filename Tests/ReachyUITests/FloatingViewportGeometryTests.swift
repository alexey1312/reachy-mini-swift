import CoreGraphics
@testable import ReachyUI
import SwiftUI
import Testing

/// The placement arithmetic on its own: a rectangle and a point in, a point out.
///
/// Split from `FloatingViewportModelTests` because none of these needs a gesture — and
/// the two suites therefore share no fixture beyond a screen to measure against.
@MainActor
@Suite("Floating viewport geometry", .timeLimit(.minutes(1)))
struct FloatingViewportGeometryTests {
    private static let portrait = CGRect(x: 0, y: 0, width: 400, height: 800)
    private static let landscape = CGRect(x: 0, y: 0, width: 800, height: 400)

    private func model(_ rest: FloatingViewportModel.Placement) -> FloatingViewportModel {
        .preview(rest)
    }

    @Test("each corner is a margin in from its own two edges", arguments: [
        (FloatingViewportModel.Corner.topLeading, CGPoint(x: 96, y: 72)),
        (.topTrailing, CGPoint(x: 304, y: 72)),
        (.bottomLeading, CGPoint(x: 96, y: 728)),
        (.bottomTrailing, CGPoint(x: 304, y: 728)),
    ])
    func cornerAnchors(corner: FloatingViewportModel.Corner, expected: CGPoint) {
        #expect(FloatingViewportModel.centre(of: corner, in: Self.portrait) == expected)
    }

    /// The corner is stored, not the point, so a rotation needs no migration — the
    /// same case simply resolves against the new rectangle.
    @Test("rotation re-resolves a floating corner")
    func rotationMovesTheCorner() {
        let model = model(.floating(.bottomTrailing))
        #expect(model.centre(in: Self.portrait) == CGPoint(x: 304, y: 728))

        model.fit(to: Self.landscape)
        #expect(model.placement == .floating(.bottomTrailing))
        #expect(model.centre(in: Self.landscape) == CGPoint(x: 704, y: 328))
    }

    /// A docked tab does carry a point, so it is the one thing rotation can strand.
    @Test("rotation pulls a docked tab back inside")
    func rotationClampsTheTab() {
        let model = model(.docked(.trailing, y: 700))

        model.fit(to: Self.landscape)
        #expect(model.placement == .docked(.trailing, y: 364))
        #expect(model.centre(in: Self.landscape) == CGPoint(x: 778, y: 364))
    }

    @Test("both edges put the tab flush against the screen", arguments: [
        (HorizontalEdge.leading, CGFloat(22)),
        (.trailing, CGFloat(378)),
    ])
    func tabHugsItsEdge(edge: HorizontalEdge, expectedX: CGFloat) {
        let model = model(.docked(edge, y: 400))

        #expect(model.centre(in: Self.portrait) == CGPoint(x: expectedX, y: 400))
    }

    // MARK: - Reaching past the safe area

    /// `bounds` stops where the safe area does, and in landscape that is 62 pt short of
    /// the glass — so the tab is pushed the rest of the way by exactly that much, and
    /// ends up straddling the rectangle's own edge.
    @Test("a bleed carries the tab out to the screen's edge", arguments: [
        (HorizontalEdge.leading, FloatingViewportModel.EdgeBleed(leading: 62), CGFloat(-40)),
        (.trailing, FloatingViewportModel.EdgeBleed(trailing: 62), CGFloat(840)),
    ])
    func bleedPushesTheTabOut(
        edge: HorizontalEdge,
        bleed: FloatingViewportModel.EdgeBleed,
        expectedX: CGFloat
    ) {
        let model = model(.docked(edge, y: 200))

        #expect(model.centre(in: Self.landscape, bleed: bleed) == CGPoint(x: expectedX, y: 200))
    }

    /// The bleed is filled in at one end only — the one with no cutout in it — so the
    /// other end has to stay exactly where it was or the tab would leave the screen on
    /// the side it was never told about.
    @Test("a bleed at one edge leaves the other edge alone")
    func bleedIsPerEdge() {
        let onlyTrailing = FloatingViewportModel.EdgeBleed(trailing: 62)

        #expect(model(.docked(.leading, y: 200)).centre(in: Self.landscape, bleed: onlyTrailing)
            == CGPoint(x: 22, y: 200))
        #expect(model(.docked(.trailing, y: 200)).centre(in: Self.landscape, bleed: .none)
            == CGPoint(x: 778, y: 200))
    }

    /// The whole reason the bleed is a parameter of `tabCentre` and not of `clamped`: a
    /// window with a picture in it belongs inside the safe area, and only the 44 pt tab
    /// belongs against the glass.
    @Test("a bleed never moves a floating corner", arguments: FloatingViewportModel.Corner.allCases)
    func bleedLeavesCornersAlone(corner: FloatingViewportModel.Corner) {
        let bled = FloatingViewportModel.centre(
            of: .floating(corner),
            in: Self.landscape,
            bleed: .init(leading: 62, trailing: 62)
        )

        #expect(bled == FloatingViewportModel.centre(of: corner, in: Self.landscape))
    }

    /// The tab may reach past the screen's side and must never reach under the tab bar,
    /// so the y clamp is deliberately blind to the bleed.
    @Test("a bleed does not loosen the vertical clamp")
    func bleedDoesNotReachTheYClamp() {
        let model = model(.docked(.trailing, y: 9999))
        let bleed = FloatingViewportModel.EdgeBleed(trailing: 62)

        #expect(model.centre(in: Self.landscape, bleed: bleed).y == 364)
    }

    /// A split view squeezed below the window's own size has no valid position at
    /// all. Centring is the only answer that is not off screen.
    @Test("a rectangle smaller than the window centres it rather than losing it")
    func degenerateBoundsCentre() {
        let tiny = CGRect(x: 0, y: 0, width: 80, height: 60)
        let middle = CGPoint(x: 40, y: 30)

        #expect(FloatingViewportModel.centre(of: .topLeading, in: tiny) == middle)
        #expect(FloatingViewportModel.centre(of: .bottomTrailing, in: tiny) == middle)
        #expect(FloatingViewportModel.clamped(CGPoint(x: 999, y: 999), in: tiny) == middle)
        #expect(FloatingViewportModel.nearestCorner(to: .zero, in: .zero) == nil)

        let pressed = FloatingViewportModel.rubberBanded(CGPoint(x: 999, y: 999), in: tiny)
        #expect(abs(pressed.x - middle.x) < 16)
        #expect(abs(pressed.y - middle.y) < 16)
    }

    // MARK: - The rubber band

    /// Inside the margins the band is the clamp — the identity is what guarantees no
    /// snapshot at rest can move, and no seam where resistance begins.
    @Test("the rubber band is the clamp wherever the clamp is not biting")
    func rubberBandIdentityInside() {
        let inside = CGPoint(x: 200, y: 400)
        let atClamp = CGPoint(x: 96, y: 72)

        #expect(FloatingViewportModel.rubberBanded(inside, in: Self.portrait) == inside)
        #expect(FloatingViewportModel.rubberBanded(atClamp, in: Self.portrait) == atClamp)
    }

    /// The clamp bites at x = 96 and the window's own edge sits at the screen's at
    /// x = 80: resistance may spend the margin between the two and no more.
    @Test("resistance is monotone and never spends more than the margin")
    func rubberBandIsBounded() {
        let near = FloatingViewportModel.rubberBanded(CGPoint(x: 76, y: 400), in: Self.portrait)
        let far = FloatingViewportModel.rubberBanded(CGPoint(x: -904, y: 400), in: Self.portrait)

        #expect(near.x < 96)
        #expect(far.x < near.x)
        #expect(far.x > 80)
    }

    /// No jump where the hard stop used to be: a point overshoot draws under a point
    /// of give.
    @Test("a small overshoot draws a smaller give")
    func rubberBandIsContinuous() {
        let nudged = FloatingViewportModel.rubberBanded(CGPoint(x: 95, y: 400), in: Self.portrait)

        #expect(nudged.x < 96)
        #expect(96 - nudged.x < 1)
    }
}
