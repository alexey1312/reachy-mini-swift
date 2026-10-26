import SwiftUI

/// Which toolbar items a crowded bar keeps longest.
///
/// iPhone Duo's vertical bars hold fewer items than a horizontal bar — on the
/// outer display above all — and when they run out of room the system moves
/// items into the overflow menu from the bottom of the bar up. A screen marks the
/// item it exists for `.high` and its rare actions `.low`, so the first thing to
/// go is the thing least missed (Apple, *Raise the bar with iPhone Duo*, 13:10).
///
/// Its own two cases rather than `ToolbarItemVisibilityPriority`, which is iOS 27
/// and macOS 26.1: below that nothing ranks items, and the modifier does nothing.
/// tvOS and visionOS declare the modifier and no value to pass it — `.high` and
/// `.low` are unavailable there, so a build for either fails on them — hence the
/// platform fork as well as the version check.
public enum ReachyToolbarPriority: Sendable {
    case low
    case high
}

public extension ToolbarContent {
    @ToolbarContentBuilder
    func reachyVisibilityPriority(_ priority: ReachyToolbarPriority) -> some ToolbarContent {
        #if os(iOS) || os(macOS)
            if #available(iOS 27.0, macOS 26.1, *) {
                visibilityPriority(priority == .high ? .high : .low)
            } else {
                self
            }
        #else
            self
        #endif
    }
}

public extension ToolbarContent {
    /// Lets an item drawn from a custom view join iPhone Duo's vertical bar.
    ///
    /// The system moves an item with a symbol into the vertical bar and keeps a
    /// custom view horizontal unless it says otherwise (Apple, *Raise the bar with
    /// iPhone Duo*, 8:00). An avatar is a symbol in all but type, and it is drawn at
    /// a glyph's size already, so it fits the bar's fixed width.
    ///
    /// iOS 27.1, and absent from the 27.0 SDKs every other platform builds
    /// against, hence the platform fork as well as the version check.
    @ToolbarContentBuilder
    func reachyVerticalPreferred() -> some ToolbarContent {
        #if os(iOS)
            if #available(iOS 27.1, *) {
                axisBehavior(.verticalPreferred)
            } else {
                self
            }
        #else
            self
        #endif
    }
}
