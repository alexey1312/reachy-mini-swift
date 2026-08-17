import SwiftUI
import WidgetKit

/// **Split into two builder properties, and it is a ceiling rather than a taste.**
/// `WidgetBundleBuilder` publishes `buildBlock` overloads for one to ten members, so
/// the eleventh — the second sound control — fails as "no exact matches in call to
/// static method 'buildBlock'", pointed at this file rather than at whatever was added
/// last. Nesting builders is the documented way past it.
@main
struct ReachyWidgetBundle: WidgetBundle {
    var body: some Widget {
        readings
        commands
    }

    /// The two that draw something the robot said.
    @WidgetBundleBuilder
    private var readings: some Widget {
        RobotStatusWidget()
        ReachyAppsWidget()
    }

    /// The buttons, in the order Control Centre's gallery lists them: power, then what
    /// the robot is doing, then what it is playing.
    @WidgetBundleBuilder
    private var commands: some Widget {
        WakeRobotControl()
        SleepRobotControl()
        PowerOffRobotControl()
        StopMoveControl()
        StopRobotAppControl()
        PlayMoveControl()
        ToggleRobotAppControl()
        PlaySoundControl()
        StopSoundControl()
    }
}
