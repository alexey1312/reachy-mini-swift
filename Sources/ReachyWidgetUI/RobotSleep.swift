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
    /// What the chase after a missing reset needs once the wait gives up: the
    /// sleep animation's own wait (`moveCompletionTimeout`) plus this, for the
    /// `goto_sleep` and `set_mode/disabled` round trips around it.
    static let requestReserve: Duration = .seconds(1)

    private let release: RobotAppRelease
    private let daemon: any RobotAPIClient
    private let power: RobotPower
    private let configuration: RobotSession.Configuration
    /// When the caller's whole command runs out, or `nil` for a caller with no
    /// such budget.
    private let deadline: ContinuousClock.Instant?

    /// The configuration is the seam a test reaches for: both halves are budgets,
    /// and the wait is the one worth shortening rather than sitting through.
    ///
    /// `deadline` is when the caller's own budget ends — an intent's
    /// `executionTimeout`, counted from before the connect. The wait for the
    /// daemon's reset gives up early enough that a chase still disables the
    /// motors before it.
    public init(
        client: any RobotAPIClient & RobotAppsClient,
        configuration: RobotSession.Configuration = .widgetIntent,
        deadline: ContinuousClock.Instant? = nil
    ) {
        self.init(apps: client, daemon: client, configuration: configuration, deadline: deadline)
    }

    /// The two halves with no client to build them from — `RobotShutdown` holds
    /// them that way, and parks through ``park(after:)`` when its plan is a sleep.
    init(
        apps: any RobotAppsClient,
        daemon: any RobotAPIClient,
        configuration: RobotSession.Configuration = .widgetIntent,
        deadline: ContinuousClock.Instant? = nil
    ) {
        release = RobotAppRelease(apps: apps, configuration: configuration)
        self.daemon = daemon
        power = RobotPower(client: daemon, configuration: configuration)
        self.configuration = configuration
        self.deadline = deadline
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
        try await park(after: release.perform())
    }

    /// Everything after the app has been dealt with.
    ///
    /// **From 1.10.0 a released app is a sleep already on its way (#166).** Freeing
    /// the slot schedules the daemon's `reset_to_sleep()` 1.5 s later, and no motion
    /// or motor route cancels it — so playing `goto_sleep` here would put a second
    /// trajectory on the head, and `set_mode/disabled` could cut the torque under
    /// the daemon's. That sleep is waited for instead, and chased only if it never
    /// comes: the user asked for a robot asleep, not for a robot the daemon was
    /// expected to put to sleep.
    ///
    /// The relay is left out by type rather than by reading: there every command
    /// cancels the reset before it runs, and so does the `get_state` frame a relayed
    /// status read is — watching would cancel what it watches. An intent reaches the
    /// robot over the LAN today, so the check is for whoever builds one otherwise.
    func park(after release: RobotAppRelease.Outcome) async throws {
        if release == .released, !(daemon is RemoteRobotConnection), await awaitIdleReset() {
            return
        }
        try await power.sleep()
    }

    /// Whether the daemon's own sleep arrived, read off the status.
    ///
    /// The first reading doubles as the version and media check, so a daemon that
    /// has no reset to wait for costs one request on its way to the animation. A
    /// robot already limp counts as asleep: there is nothing left to send either
    /// way, since the reset that picks a limp robot up is the daemon's and runs
    /// whether this waits or not. A reading that never arrived is not evidence, and
    /// only the deadline ends the wait.
    ///
    /// **That deadline is the earlier of two.** `idleResetTimeout` is counted from
    /// here, but the caller's budget started before the connect and the release,
    /// and the release alone may take its six seconds (`appStopTimeout`). A wait
    /// that ran to its own end left the chase no time: the intent was cancelled
    /// mid-sleep, reported a timeout, and left the motors enabled.
    private func awaitIdleReset() async -> Bool {
        guard let first = try? await daemon.daemonStatus(), first.resetsToSleepAfterApps else { return false }
        var deadline = ContinuousClock.now + configuration.idleResetTimeout
        if let budget = self.deadline {
            deadline = min(deadline, budget - configuration.moveCompletionTimeout - Self.requestReserve)
        }
        var reading: Components.Schemas.DaemonStatus? = first
        while !Task.isCancelled {
            if let reading, !reading.isAwake {
                return true
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: configuration.appStopPollInterval)
            reading = try? await daemon.daemonStatus()
        }
        return false
    }
}
