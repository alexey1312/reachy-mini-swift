import Foundation
import ReachyKit

/// Tearing the robot backend down, with no session around it.
///
/// The twin of `RobotSession.powerOff`, and deliberately not the same code — the
/// split `RobotAppLauncher` records at greater length. That one reads the running
/// app off state the session is already holding and reports each half's failure
/// onto a screen; this has neither, so it asks the daemon afresh and has nowhere
/// to put a sentence.
public struct RobotShutdown: Sendable {
    private let release: RobotAppRelease
    private let apps: any RobotAppsClient
    private let daemon: any RobotAPIClient
    private let sleep: RobotSleep

    /// `deadline` is when the caller's own budget ends, for the sleep-only plan's
    /// wait on the daemon's reset — see `RobotSleep`.
    public init(
        client: any RobotAPIClient & RobotAppsClient,
        configuration: RobotSession.Configuration = .widgetIntent,
        deadline: ContinuousClock.Instant? = nil
    ) {
        self.init(apps: client, daemon: client, configuration: configuration, deadline: deadline)
    }

    /// Test seam: the two halves, with no client to build them from.
    init(
        apps: any RobotAppsClient,
        daemon: any RobotAPIClient,
        configuration: RobotSession.Configuration = .widgetIntent,
        deadline: ContinuousClock.Instant? = nil
    ) {
        release = RobotAppRelease(apps: apps, configuration: configuration)
        self.apps = apps
        self.daemon = daemon
        sleep = RobotSleep(apps: apps, daemon: daemon, configuration: configuration, deadline: deadline)
    }

    /// Stops whatever holds the robot, then asks the daemon to shut the backend
    /// down with a sleep on the way — or, with an app set to start on wake-up,
    /// only puts the robot to sleep.
    ///
    /// **That exception is ``PowerOffPlan``'s, and an intent takes it without
    /// asking** because it has nobody to ask: Siri, Shortcuts and a Control
    /// Centre button all run this with no screen. The daemon only hears the
    /// antenna touch that starts that app while the backend runs, so tearing it
    /// down would switch the app off as a side effect nobody chose. The Robot
    /// screen is where the teardown is still on offer, as a second choice.
    ///
    /// **The app is stopped here because the daemon will not.** Its teardown drops
    /// the media server and the JSON-RPC relay and never touches the app manager,
    /// so an app left running has its backend go out from under it.
    ///
    /// The parking itself is the daemon's: `stop?goto_sleep=true` enables the
    /// motors, *awaits* the sleep animation and only then cuts power, which is more
    /// than `RobotPower.sleep()` does. A client-side sleep beforehand would add
    /// nothing and delay it. What it does not do is wait for the app first, which is
    /// why `RobotAppRelease` does: the daemon would otherwise start parking while
    /// the app is still handing the robot back.
    ///
    /// Failing to stop the app does not abort: the robot's body is parked either
    /// way, and that is the half that matters. `RobotSession.powerOff` reports that
    /// failure because it has a screen to report it on — an intent has one sentence
    /// and it belongs to the shutdown.
    ///
    /// The sleep-only plan parks through `RobotSleep`, released app and all: on
    /// 1.10.0 the release is a sleep already on its way, and the sleep-only plan
    /// would otherwise play a second one into it — the race `RobotSleep` exists to
    /// avoid (#166). The teardown has no such wait; `RobotSession.powerOff` says why
    /// its stop lands in time.
    public func perform() async throws {
        let plan = await PowerOffPlan.read(apps: apps, daemon: daemon)
        let released = await release.perform()
        switch plan {
        case .stopBackend:
            // Returns as soon as the daemon has accepted the job. Nothing polls it
            // afterwards: the caller is an intent, and waiting out a sixty-second
            // budget in a process that has seconds would fail with the work
            // already done and no way to say so.
            try await daemon.stopDaemon(gotoSleep: true)
        case .sleep:
            try await sleep.park(after: released)
        }
    }
}
