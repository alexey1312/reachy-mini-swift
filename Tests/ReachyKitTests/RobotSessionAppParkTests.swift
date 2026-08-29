import Foundation
@testable import ReachyKit
import Testing

/// The end of an app has to give the robot back, and the daemon only half does:
/// `AppManager.stop_current_app` carries a return-to-zero that is not observed on
/// hardware, and the crash path has none at all — `monitor_process` releases the
/// robot-app lock in its `finally` and leaves the head where the app left it.
@MainActor
@Suite("RobotSession app parking", .timeLimit(.minutes(1)))
struct RobotSessionAppParkTests {
    @Test("an app this session woke the robot for puts it back to sleep")
    func parksBySleepingWhenWeWokeIt() async throws {
        let client = AppLifecycleClient(motorMode: .disabled)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(client.recordedSteps.contains(.gotoSleep))

        #expect(client.recordedSteps.contains(.motorMode(.disabled)))
        #expect(client.neutralCalls == 0)
        session.disconnect()
    }

    @Test("an app on a robot that was already awake leaves it in the zero pose")
    func parksAtZeroWhenTheRobotWasAwake() async throws {
        let client = AppLifecycleClient()
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(client.neutralCalls == 1)

        #expect(client.neutralCalls == 1)
        #expect(client.recordedSteps.contains(.gotoSleep) == false)
        session.disconnect()
    }

    /// The load-bearing one. A stop re-reads and the poll reads again a moment
    /// later; both legitimately see the same cleared slot, so anything that fires
    /// per *reading* rather than per *transition* parks the robot twice.
    @Test("the robot is parked exactly once, however many readings see the slot clear")
    func parksExactlyOnce() async throws {
        let client = AppLifecycleClient(stoppingReads: 2)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        try await session.stopCurrentApp()
        for _ in 0 ..< 4 {
            try? await session.refreshCurrentApp()
        }
        await AppLifecycle.waitUntil(client.neutralCalls == 1)

        #expect(client.neutralCalls == 1)
        session.disconnect()
    }

    /// Guards the loop this could have been: park → `sleep()` →
    /// `releaseRunningApp()` → `stopCurrentApp()` → another reading → park.
    @Test("parking never stops the app a second time")
    func parkingDoesNotRestopTheApp() async throws {
        let client = AppLifecycleClient(motorMode: .disabled)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(client.recordedSteps.contains(.gotoSleep))

        #expect(client.recordedSteps.count { $0 == .stopApp } == 1)
        session.disconnect()
    }

    /// The daemon does nothing at all here: `monitor_process` releases the
    /// robot-app lock in its `finally` and leaves the head wherever the app's last
    /// frame put it.
    @Test("an app that crashes parks the robot too")
    func parksAfterACrash() async throws {
        let client = AppLifecycleClient()
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        client.setRunning(.preview(.error, error: "Process exited with code 1"))
        try await session.refreshCurrentApp()
        await AppLifecycle.waitUntil(client.neutralCalls == 1)

        #expect(client.neutralCalls == 1)
        session.disconnect()
    }

    @Test("an app that finishes on its own parks the robot too")
    func parksAfterASelfExit() async throws {
        let client = AppLifecycleClient()
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        client.setRunning(.preview(.done))
        try await session.refreshCurrentApp()
        await AppLifecycle.waitUntil(client.neutralCalls == 1)

        #expect(client.neutralCalls == 1)
        session.disconnect()
    }

    /// **The duration is the assertion** (project rule 7). Awaiting the parking
    /// inline instead of spawning it satisfies every count above and shows up only
    /// as a Stop button frozen for the length of a `goto`.
    ///
    /// The bound clears runner jitter rather than hugging the work. 200 ms against a
    /// 600 ms park went red on CI at 231 ms, having measured a loaded three-core
    /// runner and nothing else. Only the right branch has jitter to speak of — the
    /// wrong one sleeps the whole `neutralDelay` — so the gap buys less than the
    /// headroom does, and `refusesAStoppedBackendWithoutWaiting` bounds the same
    /// shape at the same two seconds.
    @Test("a stop returns before the parking has finished")
    func stopDoesNotWaitOutTheParking() async throws {
        let client = AppLifecycleClient(neutralDelay: .seconds(5))
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        let start = ContinuousClock.now
        try await session.stopCurrentApp()
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .seconds(2))
        await AppLifecycle.waitUntil(client.neutralCalls == 1)
        #expect(client.neutralCalls == 1)
        session.disconnect()
    }

    // MARK: - When the promise is void

    @Test("a restart is not the app letting go")
    func aRestartDoesNotPark() async throws {
        let client = AppLifecycleClient()
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        _ = try await session.restartCurrentApp()

        #expect(client.neutralCalls == 0)
        #expect(client.recordedSteps.contains(.gotoSleep) == false)
        session.disconnect()
    }

    /// Once somebody has pressed Wake up, the robot's state is theirs. Parking it
    /// back to sleep when the app ends would undo a decision they just took.
    @Test("waking the robot by hand cancels what the app owed it")
    func aManualWakeVoidsTheOwnership() async throws {
        let client = AppLifecycleClient(motorMode: .disabled)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        await session.wake()
        #expect(session.appLifecycle.wakeOwner == nil)

        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(client.neutralCalls == 1)

        #expect(client.neutralCalls == 1)
        session.disconnect()
    }

    /// Sleeping stops the app itself, so the release is reached from inside a
    /// transition that is already parking the robot. A `goto` sent into that puts
    /// two motions on one robot and one of them is dropped in silence.
    @Test("going to sleep by hand parks the robot once")
    func aManualSleepDoesNotParkTwice() async throws {
        let client = AppLifecycleClient()
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        await session.sleep()

        #expect(client.neutralCalls == 0)
        #expect(client.recordedSteps.count { $0 == .gotoSleep } == 1)
        session.disconnect()
    }

    /// A `goto` at a robot with disabled motors files a move task that travels
    /// nowhere — the same reason parking is already skipped after a recorded move.
    @Test("a robot somebody else parked is not parked again")
    func skipsTheZeroPoseOnAnAsleepRobot() async throws {
        let client = AppLifecycleClient()
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        client.park()
        session.lastStatus = .preview(motorMode: .disabled)
        try await session.stopCurrentApp()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(client.neutralCalls == 0)
        session.disconnect()
    }

    @Test("disconnecting is not an app letting go")
    func disconnectingParksNothing() async throws {
        let client = AppLifecycleClient(motorMode: .disabled)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)
        let stepsBefore = client.recordedSteps

        session.disconnect()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(client.recordedSteps == stepsBefore)
    }
}
