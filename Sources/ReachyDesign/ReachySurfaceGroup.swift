import SwiftUI

/// Neighbouring surfaces that should read as one sheet of glass rather than as a
/// row of separate panes.
///
/// It only means anything from iOS 26 / macOS 26, where `GlassEffectContainer`
/// merges the glass of everything inside it and lets two controls flow together as
/// they approach. Below that floor it renders its content untouched — so a call
/// site groups its chrome once and never forks on the version.
///
/// `spacing` is how close two surfaces come before they merge, not a layout gap:
/// the stack inside keeps its own.
///
/// - Warning: **It cannot contain a `reachySurface`, and it has no call sites for
///   that reason.** A container merges only the `glassEffect`s applied to its own
///   subviews; every `SurfaceRole` hides its glass inside a `.background`, and one
///   found there is hoisted into the merged sheet and composited *over* the
///   content. On device that refracted the Live tab's switcher labels into an
///   unreadable smear, and no reference image can show it — glass does not render
///   headless. Anything placed in here has to carry `glassEffect` on itself, which
///   costs it the opaque `baseFill` and therefore its snapshot cover.
///   `AGENTS.md` carries the measurement.
public struct ReachySurfaceGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = Space.md, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    /// visionOS has no `GlassEffectContainer`, so it renders the content untouched
    /// there, as below the floor.
    public var body: some View {
        #if os(visionOS)
            content
        #else
            if #available(iOS 26.0, macOS 26.0, *) {
                GlassEffectContainer(spacing: spacing) {
                    content
                }
            } else {
                content
            }
        #endif
    }
}
