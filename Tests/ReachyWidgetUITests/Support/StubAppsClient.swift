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
        case startApp(String)
        case startDaemon(wakeUp: Bool)
        case stopDaemon(gotoSleep: Bool)
    }

    /// A daemon that refuses, so a caller's handling of the refusal is what the
    /// test is looking at.
    struct Refused: Error, Equatable {}

    private let lock = NSLock()
    private var recorded: [Call] = []

    var running: RobotAppStatus?
    var isAwake = true
    /// The robot backend torn down, as `daemon/stop` leaves it: the daemon's own
    /// HTTP server still answers, and everything behind `get_backend` does not.
    var isBackendRunning = true
    /// A wake animation that never finishes, so a shortened completion budget is
    /// the only thing that ends the wait.
    var moveNeverFinishes = false
    var stopAppFails = false
    var stopDaemonFails = false

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
        "sleep-uuid"
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        moveNeverFinishes ? ["wake-uuid"] : []
    }

    func startDaemon(wakeUp: Bool) async throws {
        record(.startDaemon(wakeUp: wakeUp))
        lock.withLock { isBackendRunning = true }
    }

    func stopDaemon(gotoSleep: Bool) async throws {
        record(.stopDaemon(gotoSleep: gotoSleep))
        if stopDaemonFails {
            throw Refused()
        }
    }

    // MARK: - RobotAppsClient

    func currentAppStatus() async throws -> RobotAppStatus? {
        record(.currentAppStatus)
        return lock.withLock { running }
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
        lock.withLock { running = nil }
    }

    // MARK: - Fixtures

    /// A torn-down backend reports `backend_status: null`, not a mode — `daemon.stop()`
    /// sets `self.backend = None`, so there is nothing left to report a mode about.
    private var status: Components.Schemas.DaemonStatus {
        let running = lock.withLock { isBackendRunning }
        let mode = isAwake ? "enabled" : "disabled"
        let backend = running ? #"{"motor_control_mode":"\#(mode)","error":null}"# : "null"
        let json = """
        {"robot_name":"testbot","state":"\(running ? "running" : "stopped")","wireless_version":true,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":\(backend)}
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
