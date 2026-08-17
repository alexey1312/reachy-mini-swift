import SwiftUI
import WidgetKit

@main
struct ReachyWidgetBundle: WidgetBundle {
    var body: some Widget {
        RobotStatusWidget()
        ReachyAppsWidget()
        WakeRobotControl()
        SleepRobotControl()
        PowerOffRobotControl()
        StopMoveControl()
        StopRobotAppControl()
    }
}
