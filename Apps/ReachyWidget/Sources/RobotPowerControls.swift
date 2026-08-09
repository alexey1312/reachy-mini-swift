import AppIntents
import ReachyDesign
import ReachyWidgetUI
import SwiftUI
import WidgetKit

/// Wake and sleep from Control Centre, the Lock Screen or the Action button.
///
/// Buttons rather than a toggle: a toggle has to know the robot's current state
/// to draw itself, and this process cannot ask — it would have to render the
/// snapshot's guess and then contradict itself the moment the guess was stale.
/// Two buttons state what they do and nothing more.
struct WakeRobotControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "WakeRobot") {
            ControlWidgetButton(action: WakeRobotIntent()) {
                Label(.reachy("Wake up"), systemImage: "figure.wave")
            }
        }
        .displayName("Wake Reachy Mini")
        .description("Enables the motors and plays the wake-up animation.")
    }
}

struct SleepRobotControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SleepRobot") {
            ControlWidgetButton(action: SleepRobotIntent()) {
                Label(.reachy("Sleep"), systemImage: "moon.zzz.fill")
            }
        }
        .displayName("Put Reachy Mini to sleep")
        // Says the app out loud: sleeping stops whatever holds the robot, because
        // parking the motors under a running app is what kills it.
        .description("Stops the running app, plays the sleep animation, then parks the motors.")
    }
}
