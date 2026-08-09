import Foundation
@testable import ReachyKit
import Testing

/// A daemon that plays a sleep animation and runs an app, and remembers in what
/// order it was asked for each.
///
/// It models the one thing that makes the ordering hard: `stop-current-app`
/// answers 200 while the app is still being taken down, so the daemon goes on
/// naming it for a few more readings (`apps/manager.py:283`, `:355`).
private final class SleepClient: RobotAPIClient, RobotAppsClient, @unchecked Sendable {
    enum Step: Equatable {
        case stopApp
        case gotoSleep
        case motorMode(Components.Schemas.MotorControlMode)
    }

    private let lock = NSLock()
    private var steps: [Step] = []
    private var runningStatus: RobotAppStatus?
    /// Readings after the stop that still report the app as holding the robot.
    /// `Int.max` is the app that never lets go.
    private let stoppingReads: Int
    private var remainingStoppingReads = 0
    private let appStopFailure: (any Error)?
    private var appHeldTheRobotAtSleep = false
    private var statusReads = 0

    init(
        running: RobotAppStatus? = nil,
        stoppingReads: Int = 0,
        appStopFailure: (any Error)? = nil
    ) {
        runningStatus = running
        self.stoppingReads = stoppingReads
        self.appStopFailure = appStopFailure
    }

    var recordedSteps: [Step] {
        lock.withLock { steps }
    }

    /// The assertion the whole feature is about: nothing may be played while the
    /// daemon still names an app as holding the robot.
    var playedTheAnimationOverARunningApp: Bool {
        lock.withLock { appHeldTheRobotAtSleep }
    }

    var recordedStatusReads: Int {
        lock.withLock { statusReads }
    }

    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name": "testbot", "state": "running", "wireless_version": false,
         "desktop_app_daemon": false, "simulation_enabled": true, "mockup_sim_enabled": false,
         "backend_status": {"ready": true, "motor_control_mode": "enabled", "last_alive": null,
                            "control_loop_stats": {}}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(
            identity: RobotIdentity(hardwareID: "hw-1", name: "testbot", daemonVersion: "1.9.0"),
            status: status
        )
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        status
    }

    func wakeUp() async throws -> String {
        "wake-uuid"
    }

    func gotoSleep() async throws -> String {
        lock.withLock {
            steps.append(.gotoSleep)
            appHeldTheRobotAtSleep = remainingStoppingReads > 0
        }
        return "sleep-uuid"
    }

    func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        lock.withLock { steps.append(.motorMode(mode)) }
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        []
    }

    func currentAppStatus() async throws -> RobotAppStatus? {
        lock.withLock { () -> RobotAppStatus? in
            statusReads += 1
            guard remainingStoppingReads > 0 else { return runningStatus }
            if remainingStoppingReads != .max {
                remainingStoppingReads -= 1
            }
            return RobotAppStatus.preview(.stopping)
        }
    }

    /// Accepts at once and goes on reporting the app for `stoppingReads` more
    /// readings, which is what the real route does.
    func stopCurrentApp() async throws {
        if let appStopFailure {
            throw appStopFailure
        }
        lock.withLock {
            steps.append(.stopApp)
            remainingStoppingReads = stoppingReads
            runningStatus = nil
        }
    }
}

/// Going to sleep takes the motors away from whatever is driving them, and the
/// daemon does not tell the app about it: `move/play/goto_sleep` plays an
/// animation and `motors/set_mode/disabled` flips a switch. So the app is stopped
/// first, and the sleep waits for the daemon to let go of it.
@MainActor
@Suite("RobotSession sleep", .timeLimit(.minutes(1)))
struct RobotSessionSleepTests {
    private func makeSession(
        client: SleepClient,
        appStopTimeout: Duration = .seconds(10)
    ) -> RobotSession {
        var config = RobotSession.Configuration()
        config.pollInterval = .milliseconds(20)
        config.appStopTimeout = appStopTimeout
        config.appStopPollInterval = .milliseconds(10)
        return RobotSession(configuration: config) { _ in client }
    }

    private func connected(
        _ client: SleepClient,
        appStopTimeout: Duration = .seconds(10)
    ) async -> RobotSession {
        let session = makeSession(client: client, appStopTimeout: appStopTimeout)
        await session.connect(to: RobotAddress(host: "10.0.0.9"))
        try? await session.refreshCurrentApp()
        return session
    }

    @Test("the running app is stopped before the motors are taken from it")
    func stopsTheAppFirst() async {
        let client = SleepClient(running: .preview(.running))
        let session = await connected(client)

        await session.sleep()

        #expect(client.recordedSteps == [.stopApp, .gotoSleep, .motorMode(.disabled)])
        #expect(session.robotError == nil)
        #expect(session.powerTransition == nil)
        session.disconnect()
    }

    /// A 200 from `stop-current-app` is not the app letting go — the daemon clears
    /// its own slot on the last line of `stop_current_app`, past the return-to-zero
    /// it performs on the app's behalf. Playing over that puts two motions on one
    /// robot, and `play_move` takes its guard non-blocking.
    @Test("the animation waits for the daemon to stop naming the app")
    func waitsForTheAppToLetGo() async {
        let client = SleepClient(running: .preview(.running), stoppingReads: 3)
        let session = await connected(client)

        await session.sleep()

        #expect(client.playedTheAnimationOverARunningApp == false)
        #expect(client.recordedSteps == [.stopApp, .gotoSleep, .motorMode(.disabled)])
        session.disconnect()
    }

    /// The daemon's `stopping` is a one-way door no client can open, so the wait is
    /// bounded and the robot is parked regardless: a head held up for a wedge is the
    /// worse outcome. The step list is identical either way, so the elapsed time is
    /// the assertion (project rule 7).
    @Test("an app that never lets go is waited out, not waited on forever")
    func parksTheRobotAnywayWhenTheAppWedges() async {
        let client = SleepClient(running: .preview(.running), stoppingReads: .max)
        let session = await connected(client, appStopTimeout: .milliseconds(300))

        let start = ContinuousClock.now
        await session.sleep()
        let elapsed = start.duration(to: .now)

        #expect(elapsed >= .milliseconds(250))
        #expect(client.recordedSteps == [.stopApp, .gotoSleep, .motorMode(.disabled)])
        session.disconnect()
    }

    /// The mirror image, and the reason the previous test cannot stand alone: both
    /// end in the same steps and differ only in how long they take.
    @Test("an app that lets go at once is not waited out")
    func doesNotWaitOutTheBudgetWhenTheAppStops() async {
        let client = SleepClient(running: .preview(.running))
        let session = await connected(client, appStopTimeout: .seconds(30))

        let start = ContinuousClock.now
        await session.sleep()
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .seconds(10))
        session.disconnect()
    }

    @Test("an app that refuses to stop is reported and the robot is parked anyway")
    func appStopFailureDoesNotAbort() async {
        let client = SleepClient(running: .preview(.running), appStopFailure: ReachyKitError.daemonBusy)
        let session = await connected(client)

        await session.sleep()

        #expect(client.recordedSteps == [.gotoSleep, .motorMode(.disabled)])
        #expect(session.robotError == ReachyKitError.daemonBusy.errorDescription)
        session.disconnect()
    }

    /// An app that already finished is not holding anything, and asking the daemon
    /// about a robot the session has already read is a round trip a sleep does not
    /// need.
    @Test("nothing is stopped, and nothing is asked, with no app running")
    func sleepsStraightAwayWithNoApp() async {
        let client = SleepClient()
        let session = await connected(client)
        let readsBefore = client.recordedStatusReads

        await session.sleep()

        #expect(client.recordedSteps == [.gotoSleep, .motorMode(.disabled)])
        #expect(client.recordedStatusReads == readsBefore)
        session.disconnect()
    }

    @Test("a finished app is not stopped again")
    func ignoresAFinishedApp() async {
        let client = SleepClient(running: .preview(.done))
        let session = await connected(client)

        await session.sleep()

        #expect(client.recordedSteps == [.gotoSleep, .motorMode(.disabled)])
        session.disconnect()
    }

    @Test("a second sleep is ignored while one is already in flight")
    func concurrentSleepIsIgnored() async {
        let client = SleepClient(running: .preview(.running))
        let session = await connected(client)

        async let first: Void = session.sleep()
        async let second: Void = session.sleep()
        _ = await (first, second)

        #expect(client.recordedSteps == [.stopApp, .gotoSleep, .motorMode(.disabled)])
        session.disconnect()
    }
}
