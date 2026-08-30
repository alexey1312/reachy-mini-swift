import SwiftUI

/// System chrome that only exists from iOS 26 / macOS 26, wrapped so a call site
/// never carries an `#available` of its own.
///
/// Each of these is a no-op below the floor rather than a fallback: there is no
/// older control that does the same thing, and pretending otherwise would build a
/// second design nobody asked for.
public extension View {
    /// Lets the tab bar step aside while the reader scrolls down a list.
    ///
    /// **`#if os(iOS)` and not an availability check alone.** The SDK declares
    /// `tabBarMinimizeBehavior` itself for macOS 26 — so reading the method's
    /// availability suggests no platform fork is needed — while every value of
    /// `TabBarMinimizeBehavior`, `.onScrollDown` included, is
    /// `@available(macOS, unavailable)`. The method compiles there and has nothing
    /// to pass it. Which is fitting: macOS has no tab bar to minimise.
    ///
    /// **It used to take a flag, and the flag is gone rather than defaulted.** The
    /// running-app dock was an opaque strip mounted in the bottom safe area, so a
    /// minimised bar shrank into the row that strip already occupied and the whole
    /// tab bar read as having been replaced by it. The dock is a tab accessory now,
    /// which is the slot the shrinking makes room for, so minimising is the
    /// interaction rather than the thing that breaks it. Do not reintroduce the
    /// argument; see `ReachyTabAccessory`.
    @ViewBuilder
    func reachyMinimizingTabBar() -> some View {
        #if os(iOS)
            if #available(iOS 26.0, *) {
                tabBarMinimizeBehavior(.onScrollDown)
            } else {
                self
            }
        #else
            self
        #endif
    }

    /// Softens where scrolling content passes under a bar.
    ///
    /// Worth asking for only where the content is dense and unbroken — a log tail
    /// under a navigation bar. A grouped `Form` already ends in its own background,
    /// and softening that edge blurs a boundary the reader uses.
    ///
    /// **iOS 27 revised `.automatic`, and the override still earns its place.**
    /// Measured on an iPhone 17 Pro running 27.0, over a plain `List` of monospaced
    /// lines scrolled under an inline bar: `.automatic`, `.hard` and no modifier at all
    /// render the same frame to the byte, and only `.soft` differs — across the first
    /// 150 pt, which is where the effect draws. What the other three add there is a
    /// hairline under the bar, and over a log tail that reads as one more row
    /// separator, which the list hides everywhere else.
    @ViewBuilder
    func reachySoftScrollEdge(_ edges: Edge.Set) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}
