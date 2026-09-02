import SwiftUI
import WidgetKit

/// **Split into three builder properties, and it is a ceiling rather than a taste.**
/// `WidgetBundleBuilder` publishes `buildBlock` overloads for one to ten members, so
/// the eleventh — the second sound control — fails as "no exact matches in call to
/// static method 'buildBlock'", pointed at this file rather than at whatever was added
/// last. Nesting builders is the documented way past it.
@main
struct ReachyWidgetBundle: WidgetBundle {
    var body: some Widget {
        #if os(iOS)
            readings
            commands
            activities
        #else
            // The Mac gets the two readings and none of the buttons; the reason is
            // in `RobotPowerControls`, and it is the deployment target rather than
            // the platform.
            readings
        #endif
    }

    /// The two that draw something the robot said.
    @WidgetBundleBuilder
    private var readings: some Widget {
        RobotStatusWidget()
        ReachyAppsWidget()
    }

    #if os(iOS)
        /// The Live Activity. Its own property rather than a member of `readings`
        /// for the reason that split exists at all: `WidgetBundleBuilder` publishes
        /// `buildBlock` for one to ten members, and this is the twelfth thing in the
        /// bundle. It is also the one member that draws nothing until the app starts
        /// it, which is why it sits apart from the two that draw a reading.
        @WidgetBundleBuilder
        private var activities: some Widget {
            RunningAppActivity()
        }

        /// The buttons, in the order Control Centre's gallery lists them: power, then what
        /// the robot is doing, then what it is playing. iOS only — `RobotPowerControls`
        /// says why.
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
    #endif
}
