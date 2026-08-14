import ReachyDesign
import SwiftUI

/// Where the one viewport can be — the vocabulary, and the derivations every host
/// reads. `FloatingViewportGeometry` turns the two window cases into points.
///
/// It sits apart from the model because that file is at SwiftLint's limit, and it can
/// because none of this carries state: everything reached here is `private(set)` at
/// worst, while anything that *writes* `rest` or `activation` can only live in the
/// model's own file.
extension FloatingViewportModel {
    /// Which corner the window rests in. Stored as a corner and not as a point, so
    /// a rotation or a split-view resize needs no migration at all.
    enum Corner: Hashable, CaseIterable {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    /// **Four places the one viewport can be, and only ever one of them at a time.**
    /// Two are windows and two are not, which is the split `isWindowed` names: the
    /// overlay draws the two window cases, `LiveTab` draws `.inline`, and the
    /// trailing column draws `.column`.
    enum Placement: Equatable {
        /// The Live tab draws the viewport, full size. Also wherever the reader has
        /// switched the second place off, whichever of the two it would have been.
        case inline
        /// The trailing column draws it beside whichever tab is showing, and the
        /// stream is running. Where a sidebar layout puts the window a tab bar
        /// floats: a sidebar has room to keep the robot on screen, so it takes
        /// width instead of covering the content.
        case column
        /// The overlay draws it and the stream is running.
        case floating(Corner)
        /// The overlay draws a tab at the edge and the stream is stopped. `y` is
        /// the tab's centre, kept from wherever the window was let go of.
        case docked(HorizontalEdge, y: CGFloat)
    }

    /// How far past `bounds` the docked tab may reach at each horizontal edge, so it
    /// meets the screen's own edge rather than the safe area's.
    ///
    /// **It applies to the tab and to nothing else.** A window with a picture in it
    /// belongs inside the safe area; a 44 pt tab left 62 pt short of the edge reads
    /// as a window that failed to dock rather than as one hanging off the side.
    ///
    /// The two names are `Placement.docked`'s, so they mean `minX` and `maxX` and not
    /// what the layout direction says — `tabCentre` has always resolved
    /// `HorizontalEdge` that way.
    ///
    /// Zero everywhere but a landscape iPhone, and never symmetric even there: see
    /// `FloatingViewportModifier.dockBleed(in:)` for why only one edge is ever filled
    /// in.
    struct EdgeBleed: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0

        static let none = EdgeBleed()
    }

    // MARK: - What every host reads

    /// **The one derived value, and the whole of the "one at a time" guarantee.**
    ///
    /// `isLiveTabSelected` is read **only where there is a tab bar**, and that
    /// asymmetry is a bug fix rather than an oversight. A window covers the Live tab's
    /// own content, so it has to get out of the way when that tab is selected; a column
    /// sits beside it and never needs to. Letting the tab move the viewport on a
    /// sidebar gave one `RealityView` two mount points, which
    /// `ReachyScene/AGENTS.md` forbids outright — and instrumenting the real screen
    /// showed it doing exactly the damage that entry predicts: a scene made and torn
    /// down 4 ms later, `container.parent` non-nil at the next `make` (so the entity
    /// really was reparented between scenes), and **more teardowns than makes**, which
    /// also rules out sequencing the two on `onDisappear`. A sidebar therefore has one
    /// host for the whole life of the connection.
    ///
    /// `rest` is the window's own corner or edge and is never consulted for a column,
    /// which has neither.
    var placement: Placement {
        if !isEnabled {
            return .inline
        }
        if !hasTabBar {
            return .column
        }
        return isLiveTabSelected ? .inline : rest
    }

    /// The placement the geometry draws: where an animation in flight is heading, and
    /// the real one otherwise.
    ///
    /// **It answers only for the overlay, so it collapses both non-window placements
    /// to `.inline`.** The overlay is not mounted at all while the tab or the column
    /// has the viewport, and `.column` has no corner, no edge and no size of its own —
    /// the inspector decides its width. That is what keeps `drawnSize` and `drawnEdge`
    /// window arithmetic rather than switches carrying a meaningless fourth answer.
    var drawn: Placement {
        guard isWindowed else { return .inline }
        return settling ?? placement
    }

    /// The window's size at rest in whichever placement is being drawn. The content
    /// inside keeps `Metrics.floatingViewport` and is clipped by this, so the
    /// renderer's own frame never moves and the morph costs no layout.
    var drawnSize: CGSize {
        switch drawn {
        case .inline, .column, .floating: Metrics.floatingViewport
        case .docked: Metrics.viewportTab
        }
    }

    /// The edge the drawn shape is flush with, and `nil` where it is flush with
    /// nothing. Feeds `Radius.flush(to:_:)`, which is what squares off the two corners
    /// that meet the screen.
    var drawnEdge: HorizontalEdge? {
        if case let .docked(edge, _) = drawn {
            edge
        } else {
            nil
        }
    }

    /// Whether the tab owns the viewport. `LiveTab` draws exactly when this is true.
    ///
    /// **Its negation is no longer the overlay's condition** — that is `isWindowed`.
    /// With three hosts the two questions came apart, and a mount point left asking
    /// `!isInline` would put the floating window on screen beside the column.
    var isInline: Bool {
        placement == .inline
    }

    /// Whether the viewport is in the overlay rather than in a column of its own or in
    /// the tab. The one predicate `FloatingViewportModifier` and `FloatingViewport`
    /// mount on, and the one `drawn` guards with.
    var isWindowed: Bool {
        switch placement {
        case .inline, .column: false
        case .floating, .docked: true
        }
    }

    /// The one thing `RootLifecycle` asks: is anything outside the Live tab keeping the
    /// stream alive? A docked window is the off switch, so it is not — and a column
    /// always is, because it is on screen beside every other tab.
    var isStreaming: Bool {
        switch placement {
        case .column, .floating: true
        case .inline, .docked: false
        }
    }
}
