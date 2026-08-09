import Foundation
import ReachyKit

/// A daemon that records what a launcher asked of it, in order.
///
/// `RobotAPIClient` and `RobotAppsClient` both ship throwing defaults, so this
/// only implements what a toggle actually touches — anything else throwing is the
/// assertion that it was never called.
final class StubAppsClient: RobotAPIClient, RobotAppsClient, @unchecked Sendable {
    enum Call: Equatable {
        case currentAppStatus
        case stopCurrentApp
        case daemonStatus
        case setMotorMode(Components.Schemas.MotorControlMode)
        case wakeUp
        case gotoSleep
        case startApp(String)
        case stopDaemon(gotoSleep: Bool)
    }

    /// A daemon that refuses, so a caller's handling of the refusal is what the
    /// test is looking at.
    struct Refused: Error, Equatable {}

    private let lock = NSLock()
    private var recorded: [Call] = []

    var running: RobotAppStatus?
    var isAwake = true
    /// A wake animation that never finishes, so a shortened completion budget is
    /// the only thing that ends the wait.
    var moveNeverFinishes = false
    var stopAppFails = false
    var stopDaemonFails = false
    /// Readings after a stop that still name the app as holding the robot — what
    /// the real route does, since it answers 200 and clears its own slot several
    /// awaits later. `Int.max` is the app that never lets go.
    var stoppingReads = 0
    private var remainingStoppingReads = 0
    private var appHeldTheRobotAtParking = false

    /// Whether the robot was parked — by the animation or by the daemon's own
    /// teardown — while the daemon still named an app as holding it.
    var parkedOverARunningApp: Bool {
        lock.withLock { appHeldTheRobotAtParking }
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    private func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }

    // MARK: - RobotAPIClient

    func handshake() async throws -> RobotConnection.Handshake {
        .init(identity: .init(hardwareID: "hw", name: "testbot", daemonVersion: "1.9.0"), status: status)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        record(.daemonStatus)
        return status
    }

    func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        record(.setMotorMode(mode))
    }

    func wakeUp() async throws -> String {
        record(.wakeUp)
        return "wake-uuid"
    }

    func gotoSleep() async throws -> String {
        record(.gotoSleep)
        lock.withLock { appHeldTheRobotAtParking = remainingStoppingReads > 0 }
        return "sleep-uuid"
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        moveNeverFinishes ? ["wake-uuid"] : []
    }

    /// The daemon parks the robot itself on the way down, so this counts as a
    /// parking too — asking for it over a live app is the same mistake.
    func stopDaemon(gotoSleep: Bool) async throws {
        record(.stopDaemon(gotoSleep: gotoSleep))
        lock.withLock { appHeldTheRobotAtParking = remainingStoppingReads > 0 }
        if stopDaemonFails {
            throw Refused()
        }
    }

    // MARK: - RobotAppsClient

    func currentAppStatus() async throws -> RobotAppStatus? {
        record(.currentAppStatus)
        return lock.withLock { () -> RobotAppStatus? in
            guard remainingStoppingReads > 0 else { return running }
            if remainingStoppingReads != .max {
                remainingStoppingReads -= 1
            }
            return Self.status(name: "dance_party", state: "stopping")
        }
    }

    func startApp(named name: String) async throws -> RobotAppStatus {
        record(.startApp(name))
        let status = Self.status(name: name, title: name.replacingOccurrences(of: "_", with: " "))
        lock.withLock { running = status }
        return status
    }

    func stopCurrentApp() async throws {
        record(.stopCurrentApp)
        if stopAppFails {
            throw Refused()
        }
        lock.withLock {
            remainingStoppingReads = stoppingReads
            running = nil
        }
    }

    // MARK: - Fixtures

    private var status: Components.Schemas.DaemonStatus {
        let mode = isAwake ? "enabled" : "disabled"
        let json = """
        {"robot_name":"testbot","state":"running","wireless_version":true,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":{"motor_control_mode":"\(mode)","error":null}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    static func status(name: String, title: String? = nil, state: String = "running") -> RobotAppStatus {
        let card = title.map { #""cardData": {"title": "\#($0)"}"# } ?? #""cardData": {}"#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(RobotAppStatus.self, from: Data(#"""
        {"info": {"name": "\#(name)", "source_kind": "installed", "extra": {\#(card)}},
         "state": "\#(state)"}
        """#.utf8))
    }
}
