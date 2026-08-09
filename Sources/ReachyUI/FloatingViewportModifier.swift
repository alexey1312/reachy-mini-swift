import ReachyDesign
import ReachyKit
import SwiftUI

extension View {
    /// Floats the live view over the whole interface, wherever the shell draws a
    /// tab bar.
    ///
    /// **Apply this to the `TabView`.** Order against `reachyTabAccessory` no longer
    /// matters — it used to, back when the dock was a bottom `safeAreaInset` this
    /// overlay could read, and the note here said so. The strip is system chrome
    /// now, invisible to this reader like the tab bar, so `FloatingViewportModel`
    /// is told it is there instead.
    ///
    /// It is mounted in the shell rather than in the root so it dies with the
    /// connection. `.unreachable` stays in the shell, which is why a network blip
    /// leaves the window where it is instead of taking it away.
    func floatingViewport(
        model: FloatingViewportModel,
        viewport: ViewportModel,
        session: RobotSession,
        open: @escaping () -> Void
    ) -> some View {
        modifier(FloatingViewportModifier(model: model, viewport: viewport, session: session, open: open))
    }
}

private struct FloatingViewportModifier: ViewModifier {
    let model: FloatingViewportModel
    let viewport: ViewportModel
    let session: RobotSession
    let open: () -> Void

    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// **The one size-class branch in this target, and it is deliberate.** The rule
    /// is not "iPhone" but "wherever the shell draws a tab bar rather than a
    /// sidebar": a sidebar layout has the Live tab permanently beside the others
    /// and nothing to float. `ReachyUI/AGENTS.md` carries the same note, because
    /// the entry there used to say no branch was left.
    private var hasTabBar: Bool {
        #if os(macOS)
            false
        #else
            horizontalSizeClass == .compact
        #endif
    }

    /// Asked of the model rather than of `RootViewportTarget`: the window renders
    /// what the model holds, and before it has attached there is nothing to float.
    /// The Live tab asks the other question because it has to say *why* there is no
    /// live view, which the model cannot tell it.
    private var hasSomethingToShow: Bool {
        viewport.source != nil && session.isAwake
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    let bounds = available(in: geometry)
                    if hasSomethingToShow, !model.isInline {
                        FloatingViewport(
                            model: model,
                            viewport: viewport,
                            session: session,
                            bounds: bounds,
                            open: open
                        )
                        .onChange(of: bounds) { _, new in model.fit(to: new) }
                    }
                }
                .coordinateSpace(.floatingViewportBounds)
            }
            .onChange(of: hasTabBar, initial: true) { _, value in
                model.hasTabBar = value
            }
    }

    /// The region the window may rest in: this reader's own, less the chrome it
    /// cannot see.
    ///
    /// **The safe area is not subtracted here, and that is the correction.** A
    /// `GeometryReader` is laid out *inside* the safe area, so `size` has already
    /// lost it and the origin of this reader's coordinate space — the space
    /// `.position` places the window in — is already the top-left of the inset
    /// region. Subtracting `safeAreaInsets` as well counted it twice at both ends.
    /// Measured on an iPhone 17 Pro running iOS 26.4: the reader is 402 × 778 and
    /// reports t62 b34, of a 402 × 874 screen. Reaching for `ignoresSafeArea()` on
    /// the reader does not fix it either — that yields the full 402 × 874 but
    /// reports t0 b0, so there would be nothing left to subtract.
    ///
    /// What does have to be subtracted is the chrome the reader is *not* inset by:
    /// the tab bar insets each tab's content and reports none of it out here, and
    /// the accessory the running-app strip sits in does the same, which is why the
    /// shell writes `hasBottomAccessory` rather than leaving it to be measured.
    ///
    /// It can change with a finger down — the strip arrives on a poll — which is why
    /// nothing about this rectangle is captured when a gesture begins.
    private func available(in geometry: GeometryProxy) -> CGRect {
        let accessory = model.hasBottomAccessory ? Metrics.tabAccessoryAllowance : 0
        return CGRect(
            x: 0,
            y: 0,
            width: geometry.size.width,
            height: max(0, geometry.size.height - Metrics.tabBarAllowance - accessory)
        )
    }
}

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    /// The overlay's own space: the one rectangle that does not move while the window
    /// is dragged. The drag gesture rides *inside* the subtree `DragOffset` displaces,
    /// so measuring it `.local` fed the drawn offset back into the translation one
    /// frame late — the window vibrated at frame rate and tracked at half the finger's
    /// speed. This is also the space `bounds` and `.position` already live in.
    static var floatingViewportBounds: NamedCoordinateSpace {
        .named("FloatingViewport.bounds")
    }
}
