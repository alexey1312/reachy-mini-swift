import Foundation
@testable import ReachyKit
import Testing

/// A daemon that can be told to stop, and remembers in what order it was asked.
///
/// Speaks `RobotAppsClient` too, because that is the half of powering off the
/// daemon will not do for us: `Daemon.stop` drops the media server and the
/// JSON-RPC relay and never touches the app manager.
private final class PowerOffClient: RobotAPIClient, RobotAppsClient, @unchecked Sendable {
    enum Step: Equatable {
        case stopApp
        case stopDaemon(gotoSleep: Bool)
    }

    private let lock = NSLock()
    private var steps: [Step] = []
    private var state: Components.Schemas.DaemonState = .running
    /// False for the robot that accepts the request and then never finishes.
    private let stopsOnRequest: Bool
    private let stopFailure: (any Error)?
    private let appStopFailure: (any Error)?
    private var runningStatus: RobotAppStatus?
    /// Readings after the stop that still name the app, which is what the real
    /// route does: it answers 200 and clears its own slot several awaits later.
    private let stoppingReads: Int
    private var remainingStoppingReads = 0
    private var appHeldTheRobotAtStop = false

    init(
        running: RobotAppStatus? = nil,
        stopsOnRequest: Bool = true,
        stopFailure: (any Error)? = nil,
        appStopFailure: (any Error)? = nil,
        stoppingReads: Int = 0
    ) {
        runningStatus = running
        self.stopsOnRequest = stopsOnRequest
        self.stopFailure = stopFailure
        self.appStopFailure = appStopFailure
        self.stoppingReads = stoppingReads
    }

    var recordedSteps: [Step] {
        lock.withLock { steps }
    }

    /// The daemon parks the robot as part of its teardown, so being asked for it
    /// while the app is still handing the robot back is the bug, not a detail.
    var toreDownOverARunningApp: Bool {
        lock.withLock { appHeldTheRobotAtStop }
    }

    private var status: Components.Schemas.DaemonStatus {
        let currentState = lock.withLock { state }
        let backend = currentState == .running
            ? #"{"ready": true, "motor_control_mode": "enabled", "last_alive": null, "control_loop_stats": {}}"#
            : "null"
        let json = """
        {"robot_name": "testbot", "state": "\(currentState.rawValue)", "wireless_version": false,
         "desktop_app_daemon": false, "simulation_enabled": true, "mockup_sim_enabled": false,
         "backend_status": \(backend)}
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
        "sleep-uuid"
    }

    func stopDaemon(gotoSleep: Bool) async throws {
        if let stopFailure {
            throw stopFailure
        }
        lock.withLock {
            steps.append(.stopDaemon(gotoSleep: gotoSleep))
            appHeldTheRobotAtStop = remainingStoppingReads > 0
            if stopsOnRequest {
                state = .stopped
            }
        }
    }

    func currentAppStatus() async throws -> RobotAppStatus? {
        lock.withLock { () -> RobotAppStatus? in
            guard remainingStoppingReads > 0 else { return runningStatus }
            if remainingStoppingReads != .max {
                remainingStoppingReads -= 1
            }
            return RobotAppStatus.preview(.stopping)
        }
    }

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

@MainActor
@Suite("RobotSession power off", .timeLimit(.minutes(1)))
struct RobotSessionPowerOffTests {
    private func makeSession(
        client: PowerOffClient,
        stopTimeout: Duration = .seconds(5)
    ) -> RobotSession {
        var config = RobotSession.Configuration()
        config.pollInterval = .milliseconds(20)
        config.daemonStopTimeout = stopTimeout
        config.appStopTimeout = .seconds(5)
        config.appStopPollInterval = .milliseconds(10)
        return RobotSession(configuration: config) { _ in client }
    }

    private func connected(_ client: PowerOffClient, stopTimeout: Duration = .seconds(5)) async -> RobotSession {
        let session = makeSession(client: client, stopTimeout: stopTimeout)
        await session.connect(to: RobotAddress(host: "10.0.0.9"))
        return session
    }

    @Test("powering off asks the daemon to park the robot on its way down")
    func asksForSleepOnStop() async {
        let client = PowerOffClient()
        let session = await connected(client)
        await session.powerOff()
        #expect(client.recordedSteps == [.stopDaemon(gotoSleep: true)])
        #expect(session.robotError == nil)
        #expect(session.powerTransition == nil)
        session.disconnect()
    }

    @Test("the running app is stopped before the backend goes out from under it")
    func stopsTheAppFirst() async {
        let client = PowerOffClient(running: .preview(.running))
        let session = await connected(client)
        try? await session.refreshCurrentApp()
        await session.powerOff()
        #expect(client.recordedSteps == [.stopApp, .stopDaemon(gotoSleep: true)])
        #expect(session.robotError == nil)
        session.disconnect()
    }

    /// A 200 from `stop-current-app` is not the app letting go: the daemon clears
    /// its own slot several awaits later, past the return-to-zero it performs on the
    /// app's behalf. `stop?goto_sleep=true` parks the robot, so asking for it on top
    /// of that hand-back puts two motions on one robot.
    @Test("the teardown waits for the daemon to stop naming the app")
    func waitsForTheAppToLetGo() async {
        let client = PowerOffClient(running: .preview(.running), stoppingReads: 3)
        let session = await connected(client)
        try? await session.refreshCurrentApp()
        await session.powerOff()
        #expect(client.toreDownOverARunningApp == false)
        #expect(client.recordedSteps == [.stopApp, .stopDaemon(gotoSleep: true)])
        session.disconnect()
    }

    @Test("an app that refuses to stop is reported and does not cancel the shutdown")
    func appStopFailureDoesNotAbort() async {
        let client = PowerOffClient(running: .preview(.running), appStopFailure: ReachyKitError.daemonBusy)
        let session = await connected(client)
        try? await session.refreshCurrentApp()
        await session.powerOff()
        // The robot's body is parked either way, which is the half that matters.
        #expect(client.recordedSteps == [.stopDaemon(gotoSleep: true)])
        #expect(session.robotError == ReachyKitError.daemonBusy.errorDescription)
        session.disconnect()
    }

    @Test("a busy daemon is reported rather than waited out")
    func busyDaemonIsReported() async {
        let client = PowerOffClient(stopFailure: ReachyKitError.daemonBusy)
        // Long enough that waiting on it would blow the suite's time limit, so the
        // refusal has to short-circuit rather than merely arrive eventually.
        let session = await connected(client, stopTimeout: .seconds(600))
        await session.powerOff()
        #expect(client.recordedSteps.isEmpty)
        #expect(session.robotError == ReachyKitError.daemonBusy.errorDescription)
        #expect(session.powerTransition == nil)
        session.disconnect()
    }

    @Test("a backend that never stops is reported as a timeout rather than as success")
    func neverStoppingBackendTimesOut() async {
        let client = PowerOffClient(stopsOnRequest: false)
        let session = await connected(client, stopTimeout: .milliseconds(200))
        await session.powerOff()
        #expect(client.recordedSteps == [.stopDaemon(gotoSleep: true)])
        #expect(session.robotError?.contains("did not stop") == true)
        session.disconnect()
    }

    @Test("a second power off is ignored while one is already in flight")
    func concurrentPowerOffIsIgnored() async {
        let client = PowerOffClient()
        let session = await connected(client)
        async let first: Void = session.powerOff()
        async let second: Void = session.powerOff()
        _ = await (first, second)
        #expect(client.recordedSteps == [.stopDaemon(gotoSleep: true)])
        session.disconnect()
    }
}
