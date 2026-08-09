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
        appStopTimeout: Duration = .seconds(5)
    ) -> RobotSleep {
        var configuration = RobotSession.Configuration.widgetIntent
        configuration.appStopTimeout = appStopTimeout
        configuration.appStopPollInterval = .milliseconds(10)
        return RobotSleep(client: client, configuration: configuration)
    }

    @Test("the running app is stopped before the motors are taken from it")
    func stopsTheAppFirst() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")

        try await sleep(client).perform()

        #expect(client.calls == [
            .currentAppStatus,
            .stopCurrentApp,
            .currentAppStatus,
            .gotoSleep,
            .setMotorMode(.disabled),
        ])
    }

    /// A 200 from `stop-current-app` is not the app letting go — the daemon clears
    /// its own slot several awaits later, past the return-to-zero it performs on the
    /// app's behalf. Playing over that puts two motions on one robot, and
    /// `play_move` takes its guard non-blocking.
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
}
