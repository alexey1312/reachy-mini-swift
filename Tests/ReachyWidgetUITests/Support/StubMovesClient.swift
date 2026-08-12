import Foundation
import ReachyKit

/// A daemon that records what a move player asked of it, in order.
///
/// Separate from `StubAppsClient` on purpose: that one models an app manager and
/// this one models the single move slot, and the two share none of their state.
/// `RobotAPIClient` ships throwing defaults, so anything not implemented here
/// throwing is the assertion that it was never called.
final class StubMovesClient: RobotAPIClient, @unchecked Sendable {
    enum Call: Equatable {
        case daemonStatus
        case setMotorMode(Components.Schemas.MotorControlMode)
        case wakeUp
        case startDaemon(wakeUp: Bool)
        case runningMoves
        case stopMove(String)
        case stopSound
        case gotoNeutral
        case playMove(dataset: String, move: String)
    }

    struct Refused: Error, Equatable {}

    private let lock = NSLock()
    private var recorded: [Call] = []

    var isAwake = true
    var isBackendRunning = true
    /// What `GET /api/move/running` answers. Emptied by a successful stop, so a
    /// wake animation that is still playing behaves the way the daemon's does.
    var running: Set<String> = []
    var stopMoveFails = false

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
        lock.withLock { isAwake = mode == .enabled }
    }

    /// The wake animation is a move task like any dance, so it lands in the slot.
    func wakeUp() async throws -> String {
        record(.wakeUp)
        lock.withLock { _ = running.insert("wake-uuid") }
        return "wake-uuid"
    }

    /// Required by the protocol and never reached: nothing in the move path sleeps
    /// the robot, so a call here would be the test failing rather than passing.
    func gotoSleep() async throws -> String {
        throw Refused()
    }

    func startDaemon(wakeUp: Bool) async throws {
        record(.startDaemon(wakeUp: wakeUp))
        lock.withLock { isBackendRunning = true }
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        record(.runningMoves)
        return lock.withLock { running }
    }

    func stopMove(uuid: String) async throws {
        record(.stopMove(uuid))
        if stopMoveFails {
            throw Refused()
        }
        lock.withLock { _ = running.remove(uuid) }
    }

    func stopSound() async throws {
        record(.stopSound)
    }

    func gotoNeutral(duration _: TimeInterval) async throws -> String {
        record(.gotoNeutral)
        return "neutral-uuid"
    }

    func playMove(dataset: String, move: String) async throws -> String {
        record(.playMove(dataset: dataset, move: move))
        lock.withLock { _ = running.insert("move-uuid") }
        return "move-uuid"
    }

    // MARK: - Fixtures

    private var status: Components.Schemas.DaemonStatus {
        let backendRunning = lock.withLock { isBackendRunning }
        let mode = lock.withLock { isAwake } ? "enabled" : "disabled"
        let backend = backendRunning ? #"{"motor_control_mode":"\#(mode)","error":null}"# : "null"
        let json = """
        {"robot_name":"testbot","state":"\(backendRunning ? "running" : "stopped")","wireless_version":true,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":\(backend)}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }
}
