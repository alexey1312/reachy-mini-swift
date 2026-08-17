import AppIntents
import ReachyDesign
import ReachyWidgetUI
import SwiftUI
import WidgetKit

/// What the robot is *doing*, from Control Centre — the neighbours of the three
/// power controls next door.
///
/// `RobotPowerControls` argues that a control here must be a button and never a
/// toggle, because a `StaticControlConfiguration` has no data behind it and this
/// process cannot ask the robot what it is up to. Both controls in this file are
/// imperatives with no parameter at all, which is the case that reasoning was
/// written for: "stop whatever is running" names its target by being the only
/// thing there is to stop, so there is nothing to draw and nothing to go stale.
///
/// The two glyphs are deliberately close — both actions are a stop, and pretending
/// otherwise would be inventing a distinction. What tells them apart is the word,
/// which is the whole of what Control Centre's gallery shows.
struct StopMoveControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StopMove") {
            ControlWidgetButton(action: StopMoveIntent()) {
                Label(.reachy("Stop the move"), systemImage: "stop.circle")
            }
        }
        .displayName("Stop the Reachy Mini move")
        // Says the parking out loud: `RobotMovePlayer` returns the robot to its
        // neutral pose after a stop, which is not something a reader would assume
        // of a button called Stop.
        .description("Stops whichever move is playing and returns the robot to its neutral pose.")
    }
}

/// The robot runs one app at a time, so this needs no more of a target than the
/// move control does — `StopRobotAppIntent` says so where it declines to take a
/// parameter, and the reasoning is the same: asking which app is asking somebody
/// to repeat something the robot already knows.
///
/// Stopping parks the robot at zero and never sleeps it (`RobotAppLauncher.stop()`),
/// which is why this is not a quieter spelling of the Sleep control beside it.
struct StopRobotAppControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StopRobotApp") {
            ControlWidgetButton(action: StopRobotAppIntent()) {
                Label(.reachy("Stop the app"), systemImage: "stop.fill")
            }
        }
        .displayName("Stop the Reachy Mini app")
        .description("Stops whichever app is running on your robot and parks it. Does nothing if none is.")
    }
}
