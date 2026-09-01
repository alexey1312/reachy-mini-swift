import Foundation
@testable import ReachyKit

/// The daemon's move slot, as far as `RobotSession+Moves` can see it.
///
/// A file of its own because `RobotSessionMoveTests` is at SwiftLint's file
/// limit, and because two suites now drive it.
enum MoveProbe {
    case running(Set<String>)
    case failure
}

/// `LocalizedError` rather than a bare `Error`: the session funnels every
/// failure through `RobotSession.message(for:)`, which reads `errorDescription`
/// and otherwise reports Foundation's "The operation couldn't be completed"
/// sentence for a Swift error.
enum MoveFailure: Error, LocalizedError, CustomStringConvertible {
    case failed
    var description: String {
        "failed"
    }

    var errorDescription: String? {
        description
    }
}

final class MoveRobotClient: RobotAPIClient, MovePlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var nextUUID = 0
    private var running: [MoveProbe]
    private var activeUUID: String?
    var failStopMove = false
    var cancelStopMove = false
    var failStopSound = false
    var failGotoNeutral = false
    private(set) var listCalls = 0
    private(set) var events: [String] = []
    private(set) var stopSoundCalls = 0
    private(set) var gotoNeutralCalls = 0
    private(set) var lastGotoUUID: String?

    private let awake: Bool

    init(running: [MoveProbe] = [], awake: Bool = true) {
        self.running = running
        self.awake = awake
    }

    /// The move task ends on its own — a dance that reached its last frame, or one
    /// `_try_start_move` dropped. The daemon pops the uuid in `wrap_coro`'s
    /// `finally`, so from here on `move/stop` for it is a `KeyError`.
    func finishMove() {
        lock.withLock { activeUUID = nil }
    }

    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name":"testbot","state":"running","wireless_version":false,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":{"motor_control_mode":"\(awake ? "enabled" : "disabled")","error":null}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(identity: .init(hardwareID: "hw", name: "testbot", daemonVersion: "1.9.0"), status: status)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        status
    }

    func wakeUp() async throws -> String {
        "wake"
    }

    func gotoSleep() async throws -> String {
        lock.withLock { events.append("sleep") }
        return "sleep"
    }

    func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        lock.withLock { events.append("motors:\(mode.rawValue)") }
    }

    func listMoves(dataset _: String) async throws -> [String] {
        lock.withLock { listCalls += 1 }
        return ["happy_move", "wave"]
    }

    func playMove(dataset: String, move: String) async throws -> String {
        lock.withLock {
            nextUUID += 1
            activeUUID = "move-\(nextUUID)"
            events.append("play:\(dataset):\(move)")
            return activeUUID!
        }
    }

    func gotoNeutral(duration _: Double) async throws -> String {
        let shouldFail = lock.withLock {
            nextUUID += 1
            activeUUID = "goto-\(nextUUID)"
            lastGotoUUID = activeUUID
            gotoNeutralCalls += 1
            events.append("goto:\(activeUUID!)")
            return failGotoNeutral
        }
        if shouldFail {
            throw MoveFailure.failed
        }
        return lock.withLock { activeUUID! }
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        let probe = lock.withLock {
            running.isEmpty ? MoveProbe.running(activeUUID.map { [$0] } ?? []) : running.removeFirst()
        }
        switch probe {
        case let .running(uuids): return uuids
        case .failure: throw MoveFailure.failed
        }
    }

    /// A refused stop leaves the move running, which is the whole difference
    /// between a robot that would not listen and one that had already finished.
    func stopMove(uuid: String) async throws {
        let refusal: Error? = lock.withLock {
            events.append("stop:\(uuid)")
            if cancelStopMove {
                return CancellationError()
            }
            return failStopMove ? MoveFailure.failed : nil
        }
        if let refusal {
            throw refusal
        }
        lock.withLock { activeUUID = nil }
    }

    func stopSound() async throws {
        let shouldFail = lock.withLock {
            stopSoundCalls += 1
            events.append("sound")
            return failStopSound
        }
        if shouldFail {
            throw MoveFailure.failed
        }
    }
}
