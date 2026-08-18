import Foundation
import ReachyJSON
import ReachyKit

/// A robot that is not there, answering the surface a session talks to.
///
/// `RobotSession.connect(simulating:)` takes any `RobotAPIClient`, and
/// `RobotAPIClient` requires four methods — `handshake`, `daemonStatus`, `wakeUp`,
/// `gotoSleep`. Everything else has a throwing default, and **declining is the
/// honest answer**: capabilities in this app are conformances rather than flags, so
/// a screen asks `client is any SoundboardClient` and hides itself when the answer
/// is no. `Settings — Lite robot` and `Advanced — over the relay` are recorded
/// references of exactly that shape.
///
/// What it declines, and why each is not an oversight:
///
/// - **`RobotAppsClient`** — those are Python processes on a robot's own computer.
///   There is nothing to simulate short of running them.
/// - **`SoundboardClient`** — the library is a real feature with real storage, and
///   a simulator that answered `{"status": "ok"}` into silence would reproduce the
///   one failure mode that surface cannot report.
/// - **`DaemonLogClient`** — there is no daemon and so no journal. Upstream's own
///   simulator refuses the log upgrade with a 403, and inventing lines here would
///   put simulator events on a screen that says "Daemon logs".
/// - **`PresenceClient`, `HFAuthClient`, `WiFiConfigClient`, `DaemonUpdateClient`,
///   `CacheMaintenanceClient`** — a robot's Wi-Fi, its software, its Hugging Face
///   account and its caches all belong to a machine that does not exist.
/// - **Recorded moves** — Hugging Face datasets the daemon fetches. `canPlayMoves`
///   is `address != nil`, which stays false, so the screen is already right.
public final class SimulatedRobotClient: RobotAPIClient, @unchecked Sendable {
    /// What the handshake claims. 1.9.0 is this app's supported baseline, so
    /// `DaemonCompatibilityPolicy` passes it without a warning — a simulator that
    /// claimed a newer version would put a compatibility banner over itself.
    public static let daemonVersion = "1.9.0"

    private let lock = NSLock()
    private let geometry: BundledRobotGeometry
    private let robot: SimulatedRobot
    private let name: String
    private var motorMode: Components.Schemas.MotorControlMode = .disabled
    private var moveUUIDs: Set<String> = []

    /// Fails only if the bundled description cannot be parsed, which
    /// `BundledRobotGeometryTests` and `RealURDFTests` both rule out at build time.
    /// - Parameter tick: how often the pose is integrated. Exposed so a test can
    ///   hold the robot still — a move slot is only observable while the walk that
    ///   holds it is unfinished, and a real tick converges in a fraction of a second.
    public init?(name: String = "Simulator", tick: Duration = .milliseconds(20)) {
        let geometry = BundledRobotGeometry()
        guard let urdf = try? URDFParser.parse(geometry.urdf()),
              let stewart = StewartGeometry(urdf: urdf) else { return nil }
        self.geometry = geometry
        robot = SimulatedRobot(geometry: stewart, tick: tick)
        self.name = name
    }

    /// Ends the pose loop. A session that has let go of this client should call it;
    /// nothing else keeps a simulator running.
    public func shutDown() {
        robot.stop()
    }

    // MARK: - The four a session cannot do without

    public func handshake() async throws -> RobotConnection.Handshake {
        try await RobotConnection.Handshake(
            identity: RobotIdentity(
                // No hardware to have an id. `deduplicationKey` falls back to the
                // name, which is what its own doc comment anticipates.
                hardwareID: nil,
                name: name,
                daemonVersion: Self.daemonVersion
            ),
            status: daemonStatus(),
            // No `daemon/robot-name` route, because there is no daemon: the name is
            // what this client was built with.
            supportsRename: false
        )
    }

    /// Everything Track A's `flavour` and `hasCamera` read, and each field is a
    /// claim this thing can actually stand behind.
    ///
    /// `mockup_sim_enabled` earns `flavour == .mockup` and with it the
    /// "Simulation (no physics)" caption and the sentence explaining the absent
    /// Wi-Fi, update and maintenance cards. `simulation_enabled` stays false —
    /// that one means MuJoCo, and there is no physics here. `camera_specs_name` is
    /// empty, which is exactly what the daemon writes when no media server came up,
    /// and is what makes `hasCamera` false without a branch anywhere.
    /// `wireless_version` false keeps `/wifi/*` and `/update/*` closed.
    public func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        let mode = lock.withLock { motorMode }
        let json = """
        {"robot_name": "\(name)", "state": "running",
         "wireless_version": false, "desktop_app_daemon": false,
         "simulation_enabled": false, "mockup_sim_enabled": true,
         "camera_specs_name": "",
         "backend_status": {"ready": true, "motor_control_mode": "\(mode.rawValue)",
          "last_alive": null, "control_loop_stats": {}}}
        """
        return try JSONCodec.daemon.decode(
            Components.Schemas.DaemonStatus.self,
            from: Data(json.utf8)
        )
    }

    /// Wake and sleep are the motor mode plus an animation on a real robot. Here
    /// they are the motor mode plus a walk back to neutral, which is what the
    /// animation leaves behind.
    public func wakeUp() async throws -> String {
        lock.withLock { motorMode = .enabled }
        return startMove(aiming: TeleopTarget())
    }

    public func gotoSleep() async throws -> String {
        let uuid = startMove(aiming: TeleopTarget())
        lock.withLock { motorMode = .disabled }
        return uuid
    }

    // MARK: - What it can honestly answer

    public func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        lock.withLock { motorMode = mode }
    }

    public func gotoNeutral(duration _: TimeInterval) async throws -> String {
        startMove(aiming: TeleopTarget())
    }

    /// **One slot, refused in silence, and the refusal is the point.** `play_move`
    /// opens with a non-blocking guard and simply returns when a move is running —
    /// having already filed a plausible UUID through `create_move_task`. So a
    /// second caller is answered with an id and moves nothing.
    /// `RobotSession+Moves` is built entirely around that, and a simulator that
    /// helpfully queued would make its guards untestable against it.
    private func startMove(aiming target: TeleopTarget) -> String {
        let uuid = UUID().uuidString
        let claimed = lock.withLock {
            guard moveUUIDs.isEmpty else { return false }
            moveUUIDs.insert(uuid)
            return true
        }
        if claimed {
            robot.aim(at: target)
        }
        return uuid
    }

    /// The slot empties itself when the walk ends, which is when the daemon drops a
    /// UUID too — `wrap_coro`'s `finally` pops it the instant the coroutine
    /// returns. Nothing here needs a timer for that.
    public func runningMoveUUIDs() async throws -> Set<String> {
        if robot.isSettled {
            lock.withLock { moveUUIDs.removeAll() }
        }
        return lock.withLock { moveUUIDs }
    }

    public func stopMove(uuid: String) async throws {
        lock.withLock { _ = moveUUIDs.remove(uuid) }
    }

    public func urdf() async throws -> String {
        try geometry.urdf()
    }

    public func stlAsset(named filename: String) async throws -> Data {
        try geometry.stlAsset(named: filename)
    }

    /// The analytical engine, which is what a daemon runs unless it was started
    /// with `--kinematics-engine Placo`. `providesPassiveJoints` is then false and
    /// the client solves the 21 wrists itself — the same path a real robot takes.
    public func kinematicsInfo() async throws -> KinematicsInfo {
        KinematicsInfo(engine: "analytical", checksCollisions: false)
    }
}

// MARK: - Live state

extension SimulatedRobotClient: RobotStateStreaming {
    public func updates(_ options: StateStreamOptions) -> AsyncStream<StateStreamUpdate> {
        robot.updates(options)
    }
}

// MARK: - Teleop

extension SimulatedRobotClient: TeleopClient {
    public func makeTeleop() throws -> any TeleopChannel {
        SimulatedTeleopChannel(robot: robot)
    }
}

/// The joystick's end of the simulator.
///
/// `connect` and `disconnect` are genuinely nothing here — there is no socket to
/// open and no peer to wait for — which is the third shape the protocol was written
/// to accommodate, alongside a WebSocket and a data channel that was already open.
struct SimulatedTeleopChannel: TeleopChannel {
    let robot: SimulatedRobot

    func connect() async {}

    func send(_ target: TeleopTarget) async {
        robot.aim(at: target)
    }

    func disconnect() async {}
}
