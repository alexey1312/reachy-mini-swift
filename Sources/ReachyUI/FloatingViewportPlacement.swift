import SwiftUI

/// What the floating window's position can be — the vocabulary `FloatingViewportModel`
/// derives and `FloatingViewportGeometry` turns into points.
///
/// It sits apart from both because the model is at SwiftLint's file limit, and
/// because these two carry no state: everything that has to reach `rest` or
/// `activation` is `private(set)`, so it can only live in the model's own file.
extension FloatingViewportModel {
    /// Which corner the window rests in. Stored as a corner and not as a point, so
    /// a rotation or a split-view resize needs no migration at all.
    enum Corner: Hashable, CaseIterable {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    enum Placement: Equatable {
        /// The Live tab draws the viewport, full size. Also the whole of the story on
        /// a regular width, where there is no floating window, and wherever the
        /// reader has switched the window off.
        case inline
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
}
