import ReachyDesign
import ReachyKit
import SwiftUI

/// Hey Reachy on Apple TV: find a robot on this network, wake it, and drive it with a
/// game controller or the Siri Remote.
///
/// A shell of its own rather than a port of ReachyUI. That target does not compile for
/// tvOS, and its screens are touch screens: a 10-foot interface is moved by focus, so
/// it wants fewer, larger controls and no forms. What is shared is everything below
/// the views — `RobotSession`, `CandidateSweep` and `RobotBrowser` from ReachyKit, and
/// `TeleopDriver` and `GamepadTeleop` from ReachyTeleop — so the TV connects, wakes and
/// drives through the same code the phone does.
@main
struct ReachyTVApp: App {
    @State private var session = RobotSession()

    var body: some Scene {
        WindowGroup {
            TVRootView(session: session)
                // The phone's theme is a setting in ReachyUI, which the TV does not
                // link; the default theme until the TV has a settings screen.
                .reachyTheme(.fallback)
        }
    }
}
