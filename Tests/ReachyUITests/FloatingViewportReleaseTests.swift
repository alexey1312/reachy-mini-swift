import CoreGraphics
@testable import ReachyUI
import SwiftUI
import Testing

/// Where a finished gesture puts the window: the corner it snaps to, the edge it
/// hides at, and the flick-versus-carry distinction between the two.
///
/// Split from `FloatingViewportModelTests` the way the geometry suite was — the
/// placement automaton and the live-drag mechanics stay there, and the two share
/// only the gesture harness in `FloatingViewportGestures` and a screen to measure
/// against.
@MainActor
@Suite("Floating viewport release", .timeLimit(.minutes(1)))
struct FloatingViewportReleaseTests {
    private static let portrait = CGRect(x: 0, y: 0, width: 400, height: 800)

    private func model(
        _ rest: FloatingViewportModel.Placement = .floating(.bottomTrailing)
    ) -> FloatingViewportModel {
        .preview(rest, hasTabBar: true)
    }

    // MARK: - Where a release lands

    @Test("a drag that ends inside snaps to the nearest corner")
    func snapsToNearestCorner() {
        let model = model()
        // Bottom trailing is (304, 728); this lands in the top leading quadrant.
        drag(model, by: CGSize(width: -200, height: -600), in: Self.portrait)

        #expect(model.placement == .floating(.topLeading))
    }

    @Test("a drag stopping at the edge is still a drag, not a dock")
    func edgeWithoutOvershootDoesNotDock() {
        let model = model()
        // Far enough to reach the leading margin, not far enough past it.
        drag(model, by: CGSize(width: -220, height: 0), in: Self.portrait)

        #expect(model.placement == .floating(.bottomLeading))
    }

    @Test("carrying the window past its own corner's edge docks it, at the height it was")
    func overshootDocks() {
        let leading = model(.floating(.bottomLeading))
        drag(leading, by: CGSize(width: -400, height: 0), in: Self.portrait)
        leading.finishSettling()
        #expect(leading.placement == .docked(.leading, y: 728))

        let trailing = model(.floating(.topTrailing))
        drag(trailing, by: CGSize(width: 400, height: 100), in: Self.portrait)
        trailing.finishSettling()
        #expect(trailing.placement == .docked(.trailing, y: 172))
    }

    /// Hiding is offered only in the corner the window already holds. A haul across
    /// the screen changes corner, so it lands in that corner — parking at the far
    /// edge first is what arms hiding there.
    @Test("the far edge does not hide the window, it only receives it")
    func farEdgeDoesNotDock() {
        let model = model()
        drag(model, by: CGSize(width: -400, height: 0), in: Self.portrait)

        #expect(model.placement == .floating(.bottomLeading))
    }

    /// The reported miss: a fast upward flick predicts hundreds of points of x from a
    /// few degrees of sideways drift, which used to trip the overshoot and hide the
    /// window at the top of the edge. A throw that changes corner is aimed at a
    /// corner.
    @Test("a vertical flick with sideways drift changes corner, it never hides")
    func verticalFlickWithDriftDoesNotDock() {
        let model = model()
        drag(
            model,
            by: CGSize(width: 30, height: -200),
            thrown: CGSize(width: 120, height: -600),
            in: Self.portrait
        )

        #expect(model.placement == .floating(.topTrailing))
    }

    // MARK: - A flick, not a carry

    /// FaceTime's picture-in-picture needs a flick rather than a haul, and the
    /// difference is entirely in which point is tested: where the finger stopped, or
    /// where it was heading. This drag barely moves — a set-down of the same length
    /// stays floating — and docks anyway, because it was still travelling out of its
    /// own corner's edge.
    @Test("a flick at the edge docks even though the finger stopped short")
    func flickDocksWithoutOvershoot() {
        let model = model(.floating(.bottomLeading))

        drag(
            model,
            by: CGSize(width: -10, height: 0),
            thrown: CGSize(width: -100, height: 0),
            in: Self.portrait
        )

        #expect(model.drawn == .docked(.leading, y: 728))
        #expect(model.placement == .floating(.bottomLeading))

        model.finishSettling()
        #expect(model.placement == .docked(.leading, y: 728))

        let setDown = self.model(.floating(.bottomLeading))
        drag(setDown, by: CGSize(width: -10, height: 0), in: Self.portrait)
        #expect(setDown.placement == .floating(.bottomLeading))
    }

    /// And the corner is the one it was thrown at. The same release without the throw
    /// settles in the opposite corner, which is what makes this a test of the
    /// predicted point rather than of the arithmetic around it.
    @Test("a flick lands in the corner it was aimed at, not the one it left from")
    func flickPicksThePredictedCorner() {
        let thrown = model()
        drag(
            thrown,
            by: CGSize(width: -30, height: -40),
            thrown: CGSize(width: -150, height: -500),
            in: Self.portrait
        )
        #expect(thrown.placement == .floating(.topLeading))

        let settled = model()
        drag(settled, by: CGSize(width: -30, height: -40), in: Self.portrait)
        #expect(settled.placement == .floating(.bottomTrailing))
    }
}
