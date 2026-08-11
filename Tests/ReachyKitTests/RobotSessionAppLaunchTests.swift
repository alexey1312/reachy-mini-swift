import Foundation
@testable import ReachyKit
import Testing

/// Starting an app has to take the robot properly, and the daemon does not:
/// `apps/start-app` is not behind the `get_backend` dependency, so it answers 200
/// at a robot with no backend and starts the app over disabled motors at a
/// sleeping one, where every motion command is accepted and swallowed.
@MainActor
@Suite("RobotSession app launch", .timeLimit(.minutes(1)))
struct RobotSessionAppLaunchTests {
    /// The order is the assertion: motors, then the animation, then the app. A
    /// start that landed first would run over disabled motors, and one that landed
    /// on the wake animation would have its own first move dropped by
    /// `_try_start_move` without a word.
    @Test("a sleeping robot is woken before the app starts")
    func wakesAnAsleepRobotBeforeStarting() async throws {
        let client = AppLifecycleClient(motorMode: .disabled)
        let session = await AppLifecycle.connected(client)

        _ = try await session.startApp(named: AppLifecycle.installedApp)

        #expect(client.recordedSteps == [.motorMode(.enabled), .wakeUp, .startApp(AppLifecycle.installedApp)])
        session.disconnect()
    }

    @Test("an awake robot is not woken again")
    func doesNotWakeAnAwakeRobot() async throws {
        let client = AppLifecycleClient()
        let session = await AppLifecycle.connected(client)

        _ = try await session.startApp(named: AppLifecycle.installedApp)

        #expect(client.recordedSteps == [.startApp(AppLifecycle.installedApp)])
        session.disconnect()
    }

    /// A start over a running dance is accepted by the daemon and answered with a
    /// plausible UUID, and the app's first motion then vanishes — the daemon has
    /// one move slot and `play_move` takes its guard non-blocking.
    @Test("a running move is cleared before the app starts")
    func clearsTheMoveSlotFirst() async throws {
        let client = AppLifecycleClient()
        let session = await AppLifecycle.connected(client)
        session.moveActivity = .recentring(uuid: "left-over")

        _ = try await session.startApp(named: AppLifecycle.installedApp)

        #expect(client.recordedSteps == [.stopMove, .startApp(AppLifecycle.installedApp)])
        session.disconnect()
    }

    @Test("a stopped backend is refused, and nothing is started behind the user's back")
    func refusesToStartWithTheBackendDown() async {
        let client = AppLifecycleClient(state: .stopped)
        let session = await AppLifecycle.connected(client)

        await #expect(throws: ReachyKitError.backendNotRunning) {
            _ = try await session.startApp(named: AppLifecycle.installedApp)
        }

        #expect(client.recordedSteps.isEmpty)
        session.disconnect()
    }

    /// **The duration is the assertion here** (project rule 7). The wrong branch —
    /// falling through to `daemon/start?wake_up=true` and waiting the backend out —
    /// ends in the very same `backendNotRunning` ninety seconds later, so the
    /// error and the step list alone would go green over it with only `test_time`
    /// quietly grown.
    @Test("a stopped backend is refused at once, not waited out")
    func refusesAStoppedBackendWithoutWaiting() async {
        let client = AppLifecycleClient(state: .stopped)
        let session = await AppLifecycle.connected(client, daemonStartTimeout: .seconds(90))

        let start = ContinuousClock.now
        _ = try? await session.startApp(named: AppLifecycle.installedApp)
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .seconds(2))
        session.disconnect()
    }

    /// `robotError` holds the robot's connection and power and is not a fallback
    /// for anything: a Start that failed belongs to the model behind the screen
    /// that asked, which is why the wake is thrown rather than reported.
    @Test("a refused start never lands on the robot tab")
    func aRefusedStartNeverReachesTheRobotTab() async {
        let client = AppLifecycleClient(state: .stopped)
        let session = await AppLifecycle.connected(client)

        _ = try? await session.startApp(named: AppLifecycle.installedApp)

        #expect(session.robotError == nil)
        session.disconnect()
    }

    @Test("a refused start leaves the woken robot awake and owes it nothing")
    func aRefusedStartClaimsNoOwnership() async {
        let client = AppLifecycleClient(motorMode: .disabled, startFailure: ReachyKitError.daemonBusy)
        let session = await AppLifecycle.connected(client)

        _ = try? await session.startApp(named: AppLifecycle.installedApp)

        #expect(session.appLifecycle.wakeOwner == nil)
        #expect(client.recordedSteps == [.motorMode(.enabled), .wakeUp])
        session.disconnect()
    }
}
