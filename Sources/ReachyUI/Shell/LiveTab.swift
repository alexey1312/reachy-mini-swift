import ReachyDesign
import ReachyKit
import ReachyMedia
import SwiftUI

/// The viewport, full screen on every platform.
///
/// Teleop already lives here — `CameraViewport` hangs `JoystickPad` off the
/// factory this passes down — so the full controller belongs behind this tab's
/// bar rather than two taps deep in a `Form` on another one.
struct LiveTab: View {
    let session: RobotSession
    let viewport: ViewportModel
    let floating: FloatingViewportModel
    let router: ReachyRouter
    let remoteLink: RemoteRobotLink?

    /// The one record of what this robot was last asked for, owned by `ReachyTabShell`.
    /// It was `@State` here until the column became a third reader — the column, this
    /// tab's viewport, and the two joysticks that turn those behaviours off when a hand
    /// takes the head. Anything that unmounts a reader must not take the record with
    /// it, and the column unmounts this whole tab.
    let presence: PresenceModel

    var body: some View {
        @Bindable var router = router
        return NavigationStack {
            // No `ignoresSafeArea` here. It used to be the joystick's bottom
            // safe-area inset that ruled it out; the joystick is an overlay now, and
            // the reason survives the change intact — an overlay is bounded by the
            // rectangle it is applied to, so a viewport reaching past the safe area
            // would put the pad and the recentre button under the tab bar. Full-bleed
            // video is a separate decision, and it has to answer what the glass bar
            // renders once the picture passes beneath it.
            content
                .navigationTitle(.reachy("Live"))
                .hfAccountToolbar(isPresented: $router.showsAccount)
                .toolbar {
                    // Absent where this tab already *is* the controller: a link that
                    // pushes what is under it is a step to nowhere, and pushing it
                    // would put a second copy of the same `TeleopDriver` on screen.
                    if session.canTeleoperate, !tabIsController {
                        ToolbarItem {
                            NavigationLink {
                                ControllerScreen(
                                    session: session,
                                    standDown: presence.teleopStandDown(session: session)
                                )
                            } label: {
                                Label(.reachy("Controller"), systemImage: "gamecontroller")
                            }
                        }
                    }
                    ToolbarItem { optionsMenu }
                }
        }
    }

    /// The switch for the floating window, and the reason it is here rather than in
    /// Settings: this is the screen the window belongs to, and it is the one screen
    /// guaranteed to be reachable in both states — off makes every placement
    /// `.inline`, so the tab draws the viewport and carries this toolbar either way.
    ///
    /// **It is no longer behind `hasTabBar`, and that is the change rather than an
    /// oversight.** It used to be, on the reasoning that a sidebar has nothing to
    /// float — true of the window and not of the viewport, which now leaves as a
    /// column instead. Hiding the switch there left iPad and macOS with a placement
    /// and no way to refuse it.
    ///
    /// One switch, one stored key, two words for it: `hasTabBar` decides which
    /// second place the reader is looking at, so it decides what to call it. Read
    /// off the model rather than from `horizontalSizeClass`, which keeps the
    /// target's one size-class branch its only one.
    ///
    /// A menu rather than a bare icon: the complaint that led here was that the
    /// only way to put the window away could not be found, and what is found is a
    /// word, not a glyph.
    private var optionsMenu: some View {
        Menu {
            Toggle(secondPlaceName, isOn: Binding(
                get: { floating.isEnabled },
                set: { floating.setEnabled($0) }
            ))
        } label: {
            Label(
                .reachy("Live options"),
                systemImage: floating.hasTabBar ? "pip" : "sidebar.trailing"
            )
        }
    }

    /// What the second place is called where this reader is standing. Never both at
    /// once — a device draws a tab bar or a sidebar, so only one of these two words
    /// can ever be on screen.
    private var secondPlaceName: LocalizedStringResource {
        floating.hasTabBar ? .reachy("Mini window") : .reachy("Side column")
    }

    /// Both streams would keep working while the robot sleeps — the camera hangs
    /// off `get_daemon` and the state stream off a running backend — but working is
    /// not the same as worth having. A motionless pose and a still frame cost the
    /// robot's radio and this phone's battery to show nothing, and a switcher
    /// between two inert views is a control that leads nowhere. So the tab keeps
    /// its place and offers the one thing that changes the situation.
    @ViewBuilder
    private var content: some View {
        if viewportTarget == nil {
            LiveUnavailableView()
        } else if session.isAwake {
            if floating.isInline {
                ViewportView(
                    model: viewport,
                    offersCamera: session.hasCamera,
                    makeTeleop: makeTeleop,
                    robotSession: session,
                    presence: presence
                )
            } else if floating.hasTabBar {
                // The shell builds all five tabs at once, so this body runs while
                // another tab is showing — and that is exactly when the floating
                // window holds the viewport. Drawing anything live here would be
                // the second `RealityView` the whole design exists to prevent.
                Color.clear
            } else if session.canTeleoperate {
                // **The column has the picture for as long as this connection lasts,
                // so this tab is where the robot is driven from rather than watched.**
                // It is the one arrangement in the app where the controls and the live
                // view are on screen together: pushed as a screen, this `Form` covers a
                // stream that goes on running behind it, which it did on every platform
                // for as long as it shipped.
                ControllerScreen(session: session, standDown: presence.teleopStandDown(session: session))
            } else {
                ControlsUnavailableView()
            }
        } else {
            // Pinned to the top: the banner is the tab's only content, and a lone
            // card floating in the middle of an empty screen reads as a view that
            // failed to load rather than as a status about the robot.
            AsleepBanner(session: session)
                .padding()
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var viewportTarget: ViewportModel.Source? {
        RootViewportTarget.source(session: session, remoteLink: remoteLink)
    }

    /// Whether this tab is drawing the controls rather than the picture — true only
    /// under a sidebar, where the column keeps the viewport for the whole connection.
    private var tabIsController: Bool {
        !floating.isInline && !floating.hasTabBar && session.canTeleoperate
    }

    /// Absent where this connection carries no teleop, so the joystick is not
    /// offered rather than offered inert.
    private var makeTeleop: TeleopFactory? {
        guard session.canTeleoperate else { return nil }
        return { [session] in try session.makeTeleop() }
    }
}
