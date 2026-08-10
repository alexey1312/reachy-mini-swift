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
}
