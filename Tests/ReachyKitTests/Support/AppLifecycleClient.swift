import Foundation
@testable import ReachyKit

/// A daemon that runs one app and remembers, in order, everything that was asked
/// of the robot around it.
///
/// It models the two facts the feature turns on. **`start-app` does not check
/// anything**: it is not behind the `get_backend` dependency, so it succeeds at a
/// robot with no backend and at a sleeping one alike — this double therefore
/// accepts it in every state and simply records that it was asked. And
/// **`stop-current-app` answers before the daemon has let go**, so the app is
/// still named for `stoppingReads` more readings.
final class AppLifecycleClient: RobotAPIClient, MovePlaybackClient, RobotAppsClient, @unchecked Sendable {
    enum Step: Equatable {
        case motorMode(Components.Schemas.MotorControlMode)
        case wakeUp
        case gotoSleep
        case gotoNeutral
        case startApp(String)
        case restartApp
        case stopApp
        case stopMove
        case startDaemon
    }

    private let lock = NSLock()
    private var steps: [Step] = []
    private var runningStatus: RobotAppStatus?
    private var state: Components.Schemas.DaemonState
    private var motorMode: Components.Schemas.MotorControlMode
    private let stoppingReads: Int
    private var remainingStoppingReads = 0
    private let startFailure: (any Error)?
    /// How long `gotoNeutral` takes to answer. The parking must not be awaited by
    /// whoever asked for the stop, and only a slow one can prove that.
    private let neutralDelay: Duration
    /// Reported in the status, which is where the session's version gates read it.
    /// Absent by default, which every gate treats as a version it cannot read.
    private let daemonVersion: String?
    private let noMedia: Bool?
    private var statusReads = 0

    init(
        running: RobotAppStatus? = nil,
        state: Components.Schemas.DaemonState = .running,
        motorMode: Components.Schemas.MotorControlMode = .enabled,
        stoppingReads: Int = 0,
        startFailure: (any Error)? = nil,
        neutralDelay: Duration = .zero,
        daemonVersion: String? = nil,
        noMedia: Bool? = nil
    ) {
        runningStatus = running
        self.state = state
        self.motorMode = motorMode
        self.stoppingReads = stoppingReads
        self.startFailure = startFailure
        self.neutralDelay = neutralDelay
        self.daemonVersion = daemonVersion
        self.noMedia = noMedia
    }

    var recordedSteps: [Step] {
        lock.withLock { steps }
    }

    var neutralCalls: Int {
        lock.withLock { steps.count { $0 == .gotoNeutral } }
    }

    /// Whatever the app left behind, reported the way a poll would find it.
    func setRunning(_ status: RobotAppStatus?) {
        lock.withLock { runningStatus = status }
    }

    /// The robot asleep with nobody here asking — an app that parked it itself, or
    /// the daemon's own idle reset reaching its last step.
    func park() {
        lock.withLock { motorMode = .disabled }
    }

    /// How many times anything has asked for the daemon's status.
    var statusReadCount: Int {
        lock.withLock { statusReads }
    }

    private var status: Components.Schemas.DaemonStatus {
        lock.withLock {
            statusReads += 1
            return .preview(state: state, motorMode: motorMode, version: daemonVersion, noMedia: noMedia)
        }
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(
            identity: RobotIdentity(hardwareID: "hw-1", name: "testbot", daemonVersion: daemonVersion ?? "1.9.0"),
            status: status
        )
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        status
    }

    func startDaemon(wakeUp _: Bool) async throws {
        lock.withLock {
            steps.append(.startDaemon)
            state = .running
            motorMode = .enabled
        }
    }

    func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        lock.withLock {
            steps.append(.motorMode(mode))
            motorMode = mode
        }
    }

    func wakeUp() async throws -> String {
        lock.withLock { steps.append(.wakeUp) }
        return "wake-uuid"
    }

    func gotoSleep() async throws -> String {
        lock.withLock { steps.append(.gotoSleep) }
        return "sleep-uuid"
    }

    func gotoNeutral(duration _: TimeInterval) async throws -> String {
        if neutralDelay != .zero {
            try? await Task.sleep(for: neutralDelay)
        }
        lock.withLock { steps.append(.gotoNeutral) }
        return "neutral-uuid"
    }

    func stopMove(uuid _: String) async throws {
        lock.withLock { steps.append(.stopMove) }
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        []
    }

    func installedApps() async throws -> [RobotApp] {
        RobotApp.previewInstalled
    }

    func currentAppStatus() async throws -> RobotAppStatus? {
        lock.withLock { () -> RobotAppStatus? in
            guard remainingStoppingReads > 0 else { return runningStatus }
            remainingStoppingReads -= 1
            return RobotAppStatus.preview(.stopping)
        }
    }

    func startApp(named name: String) async throws -> RobotAppStatus {
        if let startFailure {
            throw startFailure
        }
        return lock.withLock {
            steps.append(.startApp(name))
            let started = RobotAppStatus.preview(.running)
            runningStatus = started
            return started
        }
    }

    func restartCurrentApp() async throws -> RobotAppStatus {
        lock.withLock {
            steps.append(.restartApp)
            let started = RobotAppStatus.preview(.running)
            runningStatus = started
            return started
        }
    }

    func stopCurrentApp() async throws {
        lock.withLock {
            steps.append(.stopApp)
            remainingStoppingReads = stoppingReads
            runningStatus = nil
        }
    }
}

/// The session both app-lifecycle suites drive, and the wait they share.
///
/// Shared rather than duplicated per suite because the configuration is the
/// delicate part: the status poll is pushed out of the way so it cannot rewrite
/// `lastStatus` under an assertion, and the two suites have to agree about that
/// or one of them measures a different robot.
@MainActor
enum AppLifecycle {
    static let installedApp = RobotApp.previewInstalled[0].name

    static func connected(
        _ client: AppLifecycleClient,
        daemonStartTimeout: Duration = .seconds(90),
        idleResetTimeout: Duration = .seconds(12),
        appStopPollInterval: Duration = .milliseconds(10),
        overRelay: Bool = false
    ) async -> RobotSession {
        var config = RobotSession.Configuration()
        config.pollInterval = .seconds(30)
        config.movePollInterval = .milliseconds(10)
        config.moveCompletionTimeout = .milliseconds(200)
        config.appStopTimeout = .milliseconds(300)
        config.appStopPollInterval = appStopPollInterval
        config.daemonStartTimeout = daemonStartTimeout
        config.idleResetTimeout = idleResetTimeout
        let session = RobotSession(configuration: config) { _ in client }
        if overRelay {
            // A transport handed over already built is what a relayed robot is.
            await session.connect(using: client)
        } else {
            await session.connect(to: RobotAddress(host: "10.0.0.9"))
        }
        return session
    }

    /// Parking is spawned rather than awaited by whoever caused it, so every
    /// assertion about it is a condition to poll — never a duration to sleep out
    /// (project rule 7).
    static func waitUntil(_ condition: @autoclosure () -> Bool) async {
        // Past the longest `neutralDelay` any test here asks for, with room for a
        // loaded runner on top: this is a safety net, never a timing assertion.
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
