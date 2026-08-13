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

    /// The one record of what this robot was last asked for, and it lives here because
    /// this tab is where both readers are: the Presence sheet inside the viewport, and
    /// the two joysticks that turn those behaviours off when a hand takes the head.
    /// `ViewportView` used to own it, which lost the record every time a sleeping robot
    /// or the floating window unmounted that view.
    @State private var presence = PresenceModel()

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
                    if session.canTeleoperate {
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
                    if floating.hasTabBar {
                        ToolbarItem { optionsMenu }
                    }
                }
        }
    }

    /// The switch for the floating window, and the reason it is here rather than in
    /// Settings: this is the screen the window belongs to, and it is the one screen
    /// guaranteed to be reachable in both states — off makes every placement
    /// `.inline`, so the tab draws the viewport and carries this toolbar either way.
    ///
    /// Behind `hasTabBar` because the window does not exist without one. A sidebar
    /// keeps Live beside every other destination, so there is nothing to float and
    /// nothing to switch off; the flag is read off the model rather than from
    /// `horizontalSizeClass`, which keeps the target's one size-class branch its
    /// only one.
    ///
    /// A menu rather than a bare icon: the complaint that led here was that the
    /// only way to put the window away could not be found, and what is found is a
    /// word, not a glyph.
    private var optionsMenu: some View {
        Menu {
            Toggle(.reachy("Mini window"), isOn: Binding(
                get: { floating.isEnabled },
                set: { floating.setEnabled($0) }
            ))
        } label: {
            Label(.reachy("Live options"), systemImage: "pip")
        }
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
            } else {
                // The shell builds all five tabs at once, so this body runs while
                // another tab is showing — and that is exactly when the floating
                // window holds the viewport. Drawing anything live here would be
                // the second `RealityView` the whole design exists to prevent.
                Color.clear
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

    /// Absent where this connection carries no teleop, so the joystick is not
    /// offered rather than offered inert.
    private var makeTeleop: TeleopFactory? {
        guard session.canTeleoperate else { return nil }
        return { [session] in try session.makeTeleop() }
    }
}
