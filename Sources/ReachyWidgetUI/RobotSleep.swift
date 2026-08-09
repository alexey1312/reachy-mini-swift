import Foundation
import ReachyKit

/// Putting the robot to sleep, with no session around it.
///
/// The twin of `RobotSession.sleep`, and deliberately not the same code — the split
/// `RobotAppLauncher` records at greater length. That one reads the running app off
/// state the session is already holding and reports each half's failure onto a
/// screen; this has neither, so it asks the daemon afresh and has nowhere to put a
/// sentence.
///
/// It is `RobotPower.sleep()` plus the step that protocol cannot take: `RobotPower`
/// holds a `RobotAPIClient` and knows nothing about apps, and giving it one would
/// put the app manager inside the wake sequence as well, where it has no business.
public struct RobotSleep: Sendable {
    private let release: RobotAppRelease
    private let power: RobotPower

    /// The configuration is the seam a test reaches for: both halves are budgets,
    /// and the wait is the one worth shortening rather than sitting through.
    public init(
        client: any RobotAPIClient & RobotAppsClient,
        configuration: RobotSession.Configuration = .widgetIntent
    ) {
        release = RobotAppRelease(apps: client, configuration: configuration)
        power = RobotPower(client: client, configuration: configuration)
    }

    /// Stops whatever holds the robot, waits for it to let go, then plays the sleep
    /// animation and parks the motors.
    ///
    /// **The app is stopped here because nothing else will.** `move/play/goto_sleep`
    /// plays an animation and `motors/set_mode/disabled` flips a switch; neither
    /// says anything to the app manager, so an app left running has the motors taken
    /// out from under it and dies on its next command.
    ///
    /// Failing to stop it does not abort: the animation and the parking are what the
    /// user asked for, and they still happen.
    public func perform() async throws {
        await release.perform()
        try await power.sleep()
    }
}
