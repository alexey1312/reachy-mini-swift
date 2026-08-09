import ReachyDesign
import SwiftUI

/// The floating window's placement arithmetic.
///
/// Pure, and deliberately static: every one of these is a function of a rectangle
/// and a point, so the whole placement automaton is testable with no view around
/// it.
extension FloatingViewportModel {
    /// How far past the margin the finger has to travel — or be heading — before
    /// letting go docks the window rather than snapping it back.
    static let dockOvershoot: CGFloat = 44

    /// Where any placement rests. The one place the three cases are turned into a
    /// point, so the window, the tab and the spring's own arithmetic cannot disagree
    /// about where something is.
    ///
    /// `.inline` has no position — the overlay is not on screen — and the middle is the
    /// only answer that is not a lie about a corner.
    static func centre(of placement: Placement, in bounds: CGRect) -> CGPoint {
        switch placement {
        case .inline:
            CGPoint(x: bounds.midX, y: bounds.midY)
        case let .floating(corner):
            centre(of: corner, in: bounds)
        case let .docked(edge, y):
            tabCentre(edge: edge, y: y, in: bounds)
        }
    }

    /// Clamped as well as anchored, so a rectangle too small to hold the window —
    /// a squeezed split view, a preview given no size — still yields a point on
    /// screen rather than one off the far edge.
    static func centre(
        of corner: Corner,
        in bounds: CGRect,
        size: CGSize = Metrics.floatingViewport,
        margin: CGFloat = Space.lg
    ) -> CGPoint {
        clamped(
            CGPoint(
                x: corner.isLeading ? bounds.minX : bounds.maxX,
                y: corner.isTop ? bounds.minY : bounds.maxY
            ),
            in: bounds,
            size: size,
            margin: margin
        )
    }

    /// Which quadrant of `bounds` a point is in. `nil` only for a degenerate
    /// rectangle, where "nearest" means nothing and the caller keeps what it had.
    static func nearestCorner(to point: CGPoint, in bounds: CGRect) -> Corner? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        switch (point.x < bounds.midX, point.y < bounds.midY) {
        case (true, true): return .topLeading
        case (false, true): return .topTrailing
        case (true, false): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    static func clamped(
        _ centre: CGPoint,
        in bounds: CGRect,
        size: CGSize = Metrics.floatingViewport,
        margin: CGFloat = Space.lg
    ) -> CGPoint {
        CGPoint(
            x: clamp(
                centre.x,
                bounds.minX + margin + size.width / 2,
                bounds.maxX - margin - size.width / 2
            ),
            y: clamp(
                centre.y,
                bounds.minY + margin + size.height / 2,
                bounds.maxY - margin - size.height / 2
            )
        )
    }

    /// iOS-scroll-style resistance past the clamp, for the *drawn* position only — a
    /// release still tests the unresisted point. The give asymptotically approaches
    /// `margin` and never reaches it, so a window hauled arbitrarily far presses up
    /// against the screen's edge without ever crossing it. A hard stop here read as
    /// the window refusing the finger.
    static func rubberBanded(
        _ centre: CGPoint,
        in bounds: CGRect,
        size: CGSize = Metrics.floatingViewport,
        margin: CGFloat = Space.lg
    ) -> CGPoint {
        let pinned = clamped(centre, in: bounds, size: size, margin: margin)
        return CGPoint(
            x: pinned.x + resisted(centre.x - pinned.x, limit: margin),
            y: pinned.y + resisted(centre.y - pinned.y, limit: margin)
        )
    }

    /// `0.55` is UIKit's classic rubber-band coefficient — an interaction constant
    /// like `dockOvershoot`, not a layout token.
    private static func resisted(_ overshoot: CGFloat, limit: CGFloat) -> CGFloat {
        guard overshoot != 0, limit > 0 else { return 0 }
        let magnitude = (1 - 1 / (abs(overshoot) * 0.55 / limit + 1)) * limit
        return overshoot < 0 ? -magnitude : magnitude
    }

    /// The tab is flush with the edge — no margin, that is what makes it read as
    /// something hanging off the side rather than as a shrunken window.
    static func tabCentre(
        edge: HorizontalEdge,
        y: CGFloat,
        in bounds: CGRect,
        size: CGSize = Metrics.viewportTab
    ) -> CGPoint {
        CGPoint(
            x: edge == .leading
                ? bounds.minX + size.width / 2
                : bounds.maxX - size.width / 2,
            y: clampedTabY(y, in: bounds, size: size)
        )
    }

    static func clampedTabY(
        _ y: CGFloat,
        in bounds: CGRect,
        size: CGSize = Metrics.viewportTab
    ) -> CGFloat {
        clamp(y, bounds.minY + size.height / 2, bounds.maxY - size.height / 2)
    }

    /// An inverted range means the window does not fit at all — a split view
    /// squeezed to nothing, a preview given no size. Centring is the only answer
    /// that is not off screen.
    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }
}

extension FloatingViewportModel.Corner {
    var isLeading: Bool {
        self == .topLeading || self == .bottomLeading
    }

    var isTop: Bool {
        self == .topLeading || self == .topTrailing
    }
}
