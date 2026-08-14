import ReachyDesign
import ReachyKit
import SwiftUI

extension View {
    /// Keeps the live view in a trailing column beside every tab, wherever the shell
    /// draws a sidebar rather than a tab bar.
    ///
    /// **Apply this to the `TabView`, the way `floatingViewport` is applied.** Two
    /// reasons, and both were measured rather than reasoned about. Inside a tab the
    /// inspector would be rebuilt on every tab change, tearing down and remounting the
    /// `RealityView` — the one thing `ReachyScene/AGENTS.md` says never to do. And an
    /// inspector placed *outside* a navigation structure is the one that gets the full
    /// height of the trailing column: on an iPad Pro 11 in portrait the column came out
    /// 280 × 1210 beside a content area of 554 × 1099, the 111 pt difference being the
    /// tab bar the content is inset by and the column is not.
    ///
    /// It is mounted in the shell rather than in the root for the reason the window is:
    /// it dies with the connection, and `.unreachable` stays in the shell so a network
    /// blip leaves the column where it is.
    func viewportColumn(
        model: FloatingViewportModel,
        viewport: ViewportModel,
        session: RobotSession,
        presence: PresenceModel
    ) -> some View {
        modifier(
            ViewportColumnModifier(
                model: model,
                viewport: viewport,
                session: session,
                presence: presence
            )
        )
    }
}

private struct ViewportColumnModifier: ViewModifier {
    let model: FloatingViewportModel
    let viewport: ViewportModel
    let session: RobotSession
    let presence: PresenceModel

    /// The same question `FloatingViewportModifier` asks of the window, and for the
    /// same reason: the model holds what is rendered, and before it has attached
    /// there is nothing to put in a column.
    private var hasSomethingToShow: Bool {
        viewport.source != nil && session.isAwake
    }

    private var isPresented: Bool {
        model.placement == .column && hasSomethingToShow
    }

    /// Absent where this connection carries no teleop, so the joystick is not offered
    /// rather than offered inert — the same rule `LiveTab` applies.
    private var makeTeleop: TeleopFactory? {
        guard session.canTeleoperate else { return nil }
        return { [session] in try session.makeTeleop() }
    }

    func body(content: Content) -> some View {
        content
            // `.constant`, never a two-way binding. SwiftUI writes back through one
            // when it collapses the inspector itself — and it collapses it whenever
            // the width class changes, which on an iPad is a Split View resize away.
            // That write would land in `setEnabled(false)`, persisting "do not offer
            // it" because a window was dragged narrower. The model is the only truth
            // about placement; the switch that writes it is in the Live tab's toolbar.
            .inspector(isPresented: .constant(isPresented)) {
                columnContent
                    .inspectorColumnWidth(
                        min: Metrics.viewportColumnMinWidth,
                        ideal: Metrics.viewportColumnIdealWidth,
                        max: Metrics.viewportColumnMaxWidth
                    )
            }
    }

    /// **The guard that keeps a second `RealityView` off the screen.** Neither the
    /// reference documentation nor WWDC23's session on inspectors says whether this
    /// builder is evaluated while the inspector is dismissed — and an `Entity` has one
    /// parent, so a viewport built here on a Live tab that is already drawing one would
    /// silently take the robot from it. Returning `Color.clear` unless the placement
    /// really is `.column` makes the question moot rather than answered: exactly one
    /// host builds the real thing whatever SwiftUI decides to evaluate.
    ///
    /// It is the same shape `LiveTab` already uses for the same reason.
    @ViewBuilder
    private var columnContent: some View {
        if isPresented {
            ViewportView(
                model: viewport,
                offersCamera: session.hasCamera,
                // The joystick rides here, over the picture, exactly as it does in
                // `CameraViewport`. The column is the only host that keeps the viewport
                // for the whole connection, so it is the one place a hand on the head
                // can also see the head.
                makeTeleop: makeTeleop,
                robotSession: session,
                presence: presence,
                dismiss: { model.setEnabled(false) }
            )
        } else {
            Color.clear
        }
    }
}
