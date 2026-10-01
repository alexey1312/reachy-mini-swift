import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// Powering off has one ordering rule and one thing it refuses to abort on, and
/// both exist because of what the daemon does *not* do: its teardown never touches
/// the app manager, so a running app is left executing against a backend that has
/// gone.
@Suite("Robot shutdown", .timeLimit(.minutes(1)))
struct RobotShutdownTests {
    private func shutdown(
        _ client: StubAppsClient,
        appStopTimeout: Duration = .seconds(5)
    ) -> RobotShutdown {
        var configuration = RobotSession.Configuration.widgetIntent
        configuration.appStopTimeout = appStopTimeout
        configuration.appStopPollInterval = .milliseconds(10)
        return RobotShutdown(apps: client, daemon: client, configuration: configuration)
    }

    @Test("the running app is stopped before the backend goes")
    func stopsTheAppFirst() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")

        try await shutdown(client).perform()

        #expect(client.calls == [
            .currentAppStatus,
            .stopCurrentApp,
            .currentAppStatus,
            .stopDaemon(gotoSleep: true),
        ])
    }

    /// A 200 from `stop-current-app` is not the app letting go: the daemon clears
    /// its own slot several awaits later, past the return-to-zero it performs on
    /// the app's behalf. `stop?goto_sleep=true` parks the robot itself, so asking
    /// for it on top of that hand-back puts two motions on one robot.
    @Test("the teardown waits for the daemon to stop naming the app")
    func waitsForTheAppToLetGo() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")
        client.stoppingReads = 3

        try await shutdown(client).perform()

        #expect(client.parkedOverARunningApp == false)
        #expect(client.calls.last == .stopDaemon(gotoSleep: true))
    }

    /// The daemon's `stopping` is a one-way door no client can open, and an intent
    /// has seconds. Both branches end in the same calls, so the elapsed time is the
    /// assertion (project rule 7).
    @Test("an app that never lets go is waited out, not waited on forever")
    func shutsDownAnywayWhenTheAppWedges() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")
        client.stoppingReads = .max

        let start = ContinuousClock.now
        try await shutdown(client, appStopTimeout: .milliseconds(300)).perform()
        let elapsed = start.duration(to: .now)

        #expect(elapsed >= .milliseconds(250))
        #expect(client.calls.last == .stopDaemon(gotoSleep: true))
    }

    /// The parking is the daemon's: `stop?goto_sleep=true` enables the motors,
    /// awaits the animation and only then cuts power, which is more than
    /// `RobotPower.sleep()` does. A client-side sleep first would only delay it.
    @Test("nothing is played client-side on the way down")
    func leavesTheSleepToTheDaemon() async throws {
        let client = StubAppsClient()

        try await shutdown(client).perform()

        #expect(client.calls == [.currentAppStatus, .stopDaemon(gotoSleep: true)])
    }

    @Test("an app that already finished is not stopped again")
    func ignoresAFinishedApp() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party", state: "done")

        try await shutdown(client).perform()

        #expect(client.calls.contains(.stopCurrentApp) == false)
    }

    /// The robot's body is parked either way, and that is the half that matters.
    /// `RobotSession.powerOff` reports this failure because it has a screen; an
    /// intent has one sentence and it belongs to the shutdown.
    @Test("failing to stop the app does not abort the shutdown")
    func shutsDownAnywayWhenTheAppWillNotStop() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")
        client.stopAppFails = true

        try await shutdown(client).perform()

        #expect(client.calls.contains(.stopDaemon(gotoSleep: true)))
    }

    /// An intent has nobody to ask, and the daemon only hears the antenna touch
    /// that starts a startup app while its backend runs — so the robot is put to
    /// sleep and the backend stays up, as Pollen's own power button does.
    @Test("a robot with a startup app is only put to sleep")
    func sleepsARobotWithAStartupApp() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")
        client.startupAppName = "dance_party"

        try await shutdown(client).perform()

        // The second reading is `RobotSleep` asking whether the daemon will sleep
        // the robot itself; one with no version to read will not.
        #expect(client.calls == [
            .daemonStatus,
            .currentAppStatus,
            .stopCurrentApp,
            .currentAppStatus,
            .daemonStatus,
            .gotoSleep,
            .setMotorMode(.disabled),
        ])
    }

    /// The sleep-only plan stops the app first, and on 1.10.0 that release is a
    /// sleep already on its way — so the plan parks through `RobotSleep` and plays
    /// nothing into it (#166).
    @Test("a startup app's sleep is left to a daemon that sleeps the robot itself")
    func leavesTheStartupSleepToTheDaemon() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")
        client.startupAppName = "dance_party"
        client.daemonVersion = "1.11.0"
        client.idleResetAfterReads = 2

        try await shutdown(client).perform()

        #expect(client.calls.contains(.stopCurrentApp))
        #expect(client.calls.contains(.gotoSleep) == false)
        #expect(client.calls.contains(.setMotorMode(.disabled)) == false)
        #expect(client.calls.contains(.stopDaemon(gotoSleep: true)) == false)
    }

    /// Nothing is left listening on a backend that is already down, and a sleep
    /// there would be refused.
    @Test("a startup app on a stopped backend is torn down as before")
    func stoppedBackendIsStillShutDown() async throws {
        let client = StubAppsClient()
        client.startupAppName = "dance_party"
        client.isBackendRunning = false

        try await shutdown(client).perform()

        #expect(client.calls == [.daemonStatus, .currentAppStatus, .stopDaemon(gotoSleep: true)])
    }

    @Test("a daemon that refuses the shutdown is reported")
    func reportsARefusedShutdown() async throws {
        let client = StubAppsClient()
        client.stopDaemonFails = true

        await #expect(throws: StubAppsClient.Refused.self) {
            try await shutdown(client).perform()
        }
    }
}
