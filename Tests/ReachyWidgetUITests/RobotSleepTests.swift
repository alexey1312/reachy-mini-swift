import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// Sleeping has the same ordering rule as powering off, one rung further up the
/// ladder: `move/play/goto_sleep` is an animation and `motors/set_mode/disabled` is
/// a switch, so neither says anything to the app manager. An app left running has
/// the motors taken out from under it and dies on its next command.
@Suite("Robot sleep", .timeLimit(.minutes(1)))
struct RobotSleepTests {
    private func sleep(
        _ client: StubAppsClient,
        appStopTimeout: Duration = .seconds(5),
        idleResetTimeout: Duration = .seconds(5)
    ) -> RobotSleep {
        var configuration = RobotSession.Configuration.widgetIntent
        configuration.appStopTimeout = appStopTimeout
        configuration.appStopPollInterval = .milliseconds(10)
        configuration.idleResetTimeout = idleResetTimeout
        return RobotSleep(client: client, configuration: configuration)
    }

    /// A daemon that sleeps the robot itself once the app slot frees (#166).
    private func parkingDaemon(running app: String? = "dance_party") -> StubAppsClient {
        let client = StubAppsClient()
        client.daemonVersion = "1.11.0"
        client.running = app.map { StubAppsClient.status(name: $0) }
        return client
    }

    @Test("the running app is stopped before the motors are taken from it")
    func stopsTheAppFirst() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")

        try await sleep(client).perform()

        // The status read asks whether the daemon will sleep the robot itself once
        // the slot frees; one with no version to read will not.
        #expect(client.calls == [
            .currentAppStatus,
            .stopCurrentApp,
            .currentAppStatus,
            .daemonStatus,
            .gotoSleep,
            .setMotorMode(.disabled),
        ])
    }

    /// A 200 from `stop-current-app` is not the app letting go — the daemon clears
    /// its own slot several awaits later, past the return-to-zero it performs on the
    /// app's behalf. Playing over that puts two motions on one robot, and the
    /// daemon runs both.
    @Test("the animation waits for the daemon to stop naming the app")
    func waitsForTheAppToLetGo() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")
        client.stoppingReads = 3

        try await sleep(client).perform()

        #expect(client.parkedOverARunningApp == false)
        #expect(client.calls.last == .setMotorMode(.disabled))
    }

    /// The daemon's `stopping` is a one-way door no client can open, and an intent
    /// has seconds. Both branches end in the same calls, so the elapsed time is the
    /// assertion (project rule 7).
    @Test("an app that never lets go is waited out, not waited on forever")
    func parksTheRobotAnywayWhenTheAppWedges() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")
        client.stoppingReads = .max

        let start = ContinuousClock.now
        try await sleep(client, appStopTimeout: .milliseconds(300)).perform()
        let elapsed = start.duration(to: .now)

        #expect(elapsed >= .milliseconds(250))
        #expect(client.calls.contains(.gotoSleep))
        #expect(client.calls.last == .setMotorMode(.disabled))
    }

    /// The mirror image, and the reason the previous test cannot stand alone.
    @Test("an app that lets go at once is not waited out")
    func doesNotWaitOutTheBudgetWhenTheAppStops() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")

        let start = ContinuousClock.now
        try await sleep(client, appStopTimeout: .seconds(30)).perform()
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .seconds(10))
    }

    @Test("nothing is stopped with no app running")
    func sleepsStraightAwayWithNoApp() async throws {
        let client = StubAppsClient()

        try await sleep(client).perform()

        #expect(client.calls == [.currentAppStatus, .gotoSleep, .setMotorMode(.disabled)])
    }

    @Test("an app that already finished is not stopped again")
    func ignoresAFinishedApp() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party", state: "done")

        try await sleep(client).perform()

        #expect(client.calls.contains(.stopCurrentApp) == false)
        #expect(client.calls.contains(.gotoSleep))
    }

    /// The animation and the parking are what the user asked for, and a refusal
    /// from the app manager is not a reason to leave the robot holding its pose.
    @Test("failing to stop the app does not abort the sleep")
    func sleepsAnywayWhenTheAppWillNotStop() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")
        client.stopAppFails = true

        try await sleep(client).perform()

        #expect(client.calls.contains(.gotoSleep))
        #expect(client.calls.last == .setMotorMode(.disabled))
    }

    /// The motors go last, or the head drops wherever the animation had reached.
    @Test("the motors are parked after the animation, not before it")
    func disablesTheMotorsLast() async throws {
        let client = StubAppsClient()

        try await sleep(client).perform()

        let played = client.calls.firstIndex(of: .gotoSleep)
        let parked = client.calls.firstIndex(of: .setMotorMode(.disabled))
        #expect(played != nil)
        #expect(parked != nil)
        #expect((played ?? 0) < (parked ?? 0))
    }

    // MARK: - A daemon that sleeps the robot itself (#166)

    /// Stopping the app frees the slot, and from 1.10.0 that schedules the daemon's
    /// own `reset_to_sleep()`, which no motion or motor route cancels. A
    /// `goto_sleep` of ours would be a second trajectory on the same head.
    @Test("a released app's sleep is left to the daemon, not played a second time")
    func leavesTheSleepToTheDaemon() async throws {
        let client = parkingDaemon()
        client.idleResetAfterReads = 3

        try await sleep(client).perform()

        #expect(client.calls.contains(.stopCurrentApp))
        #expect(client.calls.contains(.gotoSleep) == false)
        #expect(client.calls.contains(.setMotorMode(.disabled)) == false)
        // Three readings that still found it awake, and the one that did not.
        #expect(client.calls.count { $0 == .daemonStatus } == 4)
    }

    /// Unlike the parking after an app, somebody asked for this sleep — so a reset
    /// that never comes is chased rather than let go.
    @Test("a reset that never comes is chased with the sleep that was asked for")
    func chasesAMissingReset() async throws {
        let client = parkingDaemon()

        try await sleep(client, idleResetTimeout: .milliseconds(200)).perform()

        #expect(Array(client.calls.suffix(2)) == [.gotoSleep, .setMotorMode(.disabled)])
    }

    /// Only a release schedules the reset. With nothing running the old sequence is
    /// the whole of it, and not even the version is read.
    @Test("with no app running nothing is waited for, whatever the daemon")
    func noAppNoWait() async throws {
        let client = parkingDaemon(running: nil)

        try await sleep(client).perform()

        #expect(client.calls == [.currentAppStatus, .gotoSleep, .setMotorMode(.disabled)])
    }

    @Test(
        "a daemon with no reset of its own costs one reading on the way to the animation",
        arguments: [
            ("1.9.0" as String?, nil as Bool?),
            (nil, nil),
            ("1.11.0", true),
        ]
    )
    func readsOnceWhereThereIsNoReset(version: String?, noMedia: Bool?) async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")
        client.daemonVersion = version
        client.noMedia = noMedia

        try await sleep(client).perform()

        #expect(client.calls == [
            .currentAppStatus,
            .stopCurrentApp,
            .currentAppStatus,
            .daemonStatus,
            .gotoSleep,
            .setMotorMode(.disabled),
        ])
    }

    /// A refused stop frees nothing, so nothing is scheduled to wait for.
    @Test("a stop the daemon refused is not waited on")
    func aRefusedStopIsNotWaitedOn() async throws {
        let client = parkingDaemon()
        client.stopAppFails = true

        try await sleep(client).perform()

        #expect(client.calls.contains(.daemonStatus) == false)
        #expect(Array(client.calls.suffix(2)) == [.gotoSleep, .setMotorMode(.disabled)])
    }
}
