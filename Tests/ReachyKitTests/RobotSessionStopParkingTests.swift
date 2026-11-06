import Foundation
@testable import ReachyKit
import Testing

/// From 1.14.0 a stop somebody asked for leaves the robot awake in the zero pose
/// (pollen-robotics/reachy_mini#1488). Only an app that ended by itself still takes the
/// daemon's idle reset, so the session has to tell the two apart, and the reading that
/// noticed the end is what can: a stop clears the slot, and an ended app stays named.
@MainActor
@Suite("RobotSession after an app on daemon 1.14", .timeLimit(.minutes(1)))
struct RobotSessionStopParkingTests {
    private static let daemon = "1.14.0"

    /// The transitions shown over the window in which a session waiting for the daemon
    /// would claim one. A negative has no condition to poll, so it is sampled, the way
    /// `RobotSessionDaemonParkingTests.anAsleepRobotAnnouncesNothing` samples it.
    private func transitions(on session: RobotSession) async -> [RobotSession.PowerTransition] {
        var seen: [RobotSession.PowerTransition] = []
        for _ in 0 ..< 20 {
            if let transition = session.powerTransition {
                seen.append(transition)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return seen
    }

    /// The regression this file exists for: waiting here shows "going to sleep" with
    /// every control off for 12 s, over a robot that is not going anywhere.
    @Test("a stop on an awake robot claims no transition and sends nothing")
    func aStopLeavesTheRobotAwake() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.daemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        try await session.stopCurrentApp()
        let seen = await transitions(on: session)

        #expect(seen.isEmpty)
        #expect(session.isAwake)
        #expect(client.recordedSteps == [.startApp(AppLifecycle.installedApp), .stopApp])
        session.disconnect()
    }

    /// **The duration is the second assertion** (project rule 7): a session that waited
    /// out the daemon first ends in exactly these steps, 12 s later.
    @Test("a robot woken for the app goes back to sleep at once after a stop")
    func aStopPutsAWokenRobotToSleepAtOnce() async throws {
        let client = AppLifecycleClient(motorMode: .disabled, daemonVersion: Self.daemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)
        let woken = client.recordedSteps

        let stopped = ContinuousClock.now
        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(client.recordedSteps.last == .motorMode(.disabled))

        #expect(stopped.duration(to: .now) < .seconds(5))
        #expect(client.recordedSteps == woken + [.stopApp, .gotoSleep, .motorMode(.disabled)])
        #expect(session.appLifecycle.wakeOwner == nil)
        session.disconnect()
    }

    /// `done` is a clean exit and `error` a crash. Neither went through
    /// `stop_current_app`, so the idle reset is still on its way.
    @Test("an app that ended by itself is still the daemon's sleep", arguments: [
        RobotAppStatus.State.done, .error,
    ])
    func anAppThatEndedByItselfIsStillTheDaemons(state: RobotAppStatus.State) async throws {
        let client = AppLifecycleClient(daemonVersion: Self.daemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        client.setRunning(.preview(state))
        try await session.refreshCurrentApp()
        await AppLifecycle.waitUntil(session.powerTransition == .goingToSleep)
        #expect(session.powerTransition == .goingToSleep)

        client.park()
        await AppLifecycle.waitUntil(session.powerTransition == nil)

        #expect(session.isAwake == false)
        #expect(client.recordedSteps == [.startApp(AppLifecycle.installedApp)])
        session.disconnect()
    }

    /// A stop whose process exits before the daemon cancels its monitor reads as `error`
    /// until the lift to zero ends. Measured on 1.14.0: the log shows the exit once in a
    /// handful of stops. **The duration is the assertion** (project rule 7): without the
    /// exit this holds "going to sleep" for all of the 12 s budget.
    @Test("a stop that read as an ended app ends the wait when the slot clears")
    func aStopReadAsAnEndedApp() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.daemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        client.setRunning(.preview(.error))
        try await session.refreshCurrentApp()
        await AppLifecycle.waitUntil(session.powerTransition == .goingToSleep)
        #expect(session.powerTransition == .goingToSleep)

        let cleared = ContinuousClock.now
        client.setRunning(nil)
        await AppLifecycle.waitUntil(session.powerTransition == nil)

        #expect(cleared.duration(to: .now) < .seconds(5))
        #expect(session.isAwake)
        #expect(client.recordedSteps == [.startApp(AppLifecycle.installedApp)])
        session.disconnect()
    }

    /// The same read, and the promise to a robot this session woke is still paid.
    @Test("a robot woken for the app still goes back to sleep after that read")
    func aStopReadAsAnEndedAppPaysThePromise() async throws {
        let client = AppLifecycleClient(motorMode: .disabled, daemonVersion: Self.daemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)
        let woken = client.recordedSteps

        client.setRunning(.preview(.error))
        try await session.refreshCurrentApp()
        await AppLifecycle.waitUntil(session.powerTransition == .goingToSleep)
        client.setRunning(nil)
        await AppLifecycle.waitUntil(client.recordedSteps.last == .motorMode(.disabled))

        #expect(client.recordedSteps == woken + [.gotoSleep, .motorMode(.disabled)])
        session.disconnect()
    }

    /// The daemon runs `reset_to_init()` for every backend, media server or none, so
    /// the zero pose needs no `goto` on a daemon that has no reset to run either.
    @Test("a stop sends no parking on a daemon with no media server")
    func aStopNeedsNoParkingWithoutMedia() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.daemon, noMedia: true)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        try await session.stopCurrentApp()
        let seen = await transitions(on: session)

        #expect(seen.isEmpty)
        #expect(client.neutralCalls == 0)
        session.disconnect()
    }

    /// With no media server nothing puts this robot to sleep, so an app that ended by
    /// itself is the one case in which the session still has a head to bring back.
    @Test("an app that ended by itself is still parked at zero with no media server")
    func anEndedAppIsParkedWithoutMedia() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.daemon, noMedia: true)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        client.setRunning(.preview(.done))
        try await session.refreshCurrentApp()
        await AppLifecycle.waitUntil(client.neutralCalls == 1)

        #expect(client.neutralCalls == 1)
        session.disconnect()
    }

    @Test(
        "only a daemon before 1.14.0 sleeps after a stop",
        arguments: [
            (nil as String?, false),
            ("1.9.0", false),
            ("1.10.0", true),
            ("1.13.0", true),
            ("1.14.0", false),
            ("1.14.0rc1", false),
            ("1.15.0", false),
        ]
    )
    func gate(version: String?, parks: Bool) async {
        let client = AppLifecycleClient(daemonVersion: version)
        let session = await AppLifecycle.connected(client)

        #expect(session.daemonParksAfterRequestedStop == parks)
        session.disconnect()
    }
}
