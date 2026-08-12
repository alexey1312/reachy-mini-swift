import Foundation
import ReachyJSON

/// The daemon, reached over a WebRTC session instead of over HTTP.
///
/// Deliberately a `RobotAPIClient` like `RobotConnection`, so `RobotSession` and
/// the screens above it do not have to know which way the robot was reached. It
/// is an honest subset, not a facade: everything the data channel does not carry
/// is left on the protocol's throwing defaults rather than stubbed out. Moves,
/// URDF, kinematics, the robot's own name and `/wifi`, `/update` are all
/// HTTP-only, and asking for them here fails rather than lies.
///
/// The command names and their fields are `reachy_mini/io/protocol.py`; the reply
/// shapes are `process_command` in `daemon/backend/abstract.py`.
public actor RemoteRobotConnection: RobotAPIClient {
    let control: RemoteControlChannel
    /// No command answers the robot's name, so it comes from the central listing
    /// that got us to this robot — the same place the user picked it from.
    private let robotName: String?
    /// Asked once and held: neither changes for the life of a session, and the
    /// status poll runs every three seconds.
    private var identityCache: (version: String, hardwareID: String)?

    public init(control: RemoteControlChannel, robotName: String? = nil) {
        self.control = control
        self.robotName = robotName
    }

    public init(
        channel: any RemoteDataChannel,
        robotName: String? = nil,
        timeout: Duration = .seconds(10),
        openingTimeout: Duration = .seconds(30)
    ) {
        self.init(
            control: RemoteControlChannel(
                channel: channel,
                timeout: timeout,
                openingTimeout: openingTimeout
            ),
            robotName: robotName
        )
    }

    public func handshake() async throws -> RobotConnection.Handshake {
        let status = try await daemonStatus()
        return RobotConnection.Handshake(
            identity: RobotIdentity(
                hardwareID: status.hardwareId,
                name: robotName,
                daemonVersion: status.version
            ),
            status: status,
            // Renaming is `POST /api/daemon/robot-name` and no command on this
            // channel carries it, so the field is greyed out rather than left to
            // fail on save.
            supportsRename: false
        )
    }

    /// Assembled rather than fetched. The daemon publishes `daemon_status` once a
    /// second, but only to its WebSocket clients — `Daemon._publish_status` calls
    /// `ws_server.publish_status`, not `broadcast_to_all_clients` — so it never
    /// reaches the data channel and there is no command that asks for it.
    ///
    /// Every field below is either read off the channel, carried in from central,
    /// or a value that *closes* a feature rather than opening one:
    ///
    /// - `state` is `.running` because the data-channel handler is installed on
    ///   the backend (`setup_media_server`); a reply proves the backend is up.
    /// - `wirelessVersion` is `false` because it gates `/wifi/*` and `/update/*`,
    ///   HTTP routes on the robot's own network that this session genuinely
    ///   cannot reach. The camera is *not* gated on it any more — a relay session
    ///   carries video on the same peer connection, which `RobotSession.hasCamera`
    ///   now answers from the link instead.
    /// - `backendStatus` carries the motor mode, and only that. `get_state` is
    ///   the one place this channel reports it, and it is what `isAwake` gates on
    ///   — while this returned `nil` a remote robot read as permanently asleep
    ///   however awake it was, which disabled teleop, moves and the viewport.
    ///
    /// A quiet or unrecognised `get_state` leaves the mode unknown rather than
    /// failing the whole status. Transport failures still escape: once identity
    /// is cached this is the poll's only proof that the relay remains alive.
    public func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        let identity = try await identity()
        let motorMode: String?
        do {
            motorMode = try await control.perform(
                "get_state",
                correlation: .replyKey("state"),
                expecting: StateReply.self
            ).state.motorMode
        } catch RemoteControlChannel.Failure.timedOut {
            motorMode = nil
        } catch RemoteControlChannel.Failure.robot {
            motorMode = nil
        } catch is DecodingError {
            motorMode = nil
        } catch {
            throw error
        }
        return try Self.status(
            robotName: robotName ?? "",
            version: identity.version,
            hardwareID: identity.hardwareID,
            motorMode: motorMode
        )
    }

    private func identity() async throws -> (version: String, hardwareID: String) {
        if let identityCache {
            return identityCache
        }
        let version = try await control.perform(
            "get_version",
            correlation: .replyKey("version"),
            expecting: VersionReply.self
        )
        let hardware = try await control.perform(
            "get_hardware_id",
            correlation: .replyKey("hardware_id"),
            expecting: HardwareIDReply.self
        )
        let identity = (version: version.version, hardwareID: hardware.hardwareID)
        identityCache = identity
        return identity
    }

    /// Built by decoding the daemon's own wire format rather than through the
    /// generated memberwise initialiser: `backend_status` is a `oneOf` whose Swift
    /// shape changes whenever the spec is refreshed, while the JSON is the stable
    /// thing to build against — the same reasoning as `DaemonStatus.preview`.
    static func status(
        robotName: String,
        version: String,
        hardwareID: String,
        motorMode: String?
    ) throws -> Components.Schemas.DaemonStatus {
        let backend = motorMode.map {
            #"{"ready": true, "motor_control_mode": "\#($0)", "last_alive": null, "control_loop_stats": {}}"#
        } ?? "null"
        let json = """
        {"robot_name": \(Self.quoted(robotName)), "state": "running",
         "wireless_version": false, "desktop_app_daemon": false,
         "version": \(Self.quoted(version)), "hardware_id": \(Self.quoted(hardwareID)),
         "backend_status": \(backend)}
        """
        return try JSONCodec.daemon.decode(
            Components.Schemas.DaemonStatus.self,
            from: Data(json.utf8)
        )
    }

    /// The robot's name comes from a central listing and is whatever its owner
    /// typed, so it reaches this JSON escaped rather than interpolated raw.
    private static func quoted(_ value: String) -> String {
        guard let encoded = try? JSONCodec.daemon.encode(value),
              let text = String(bytes: encoded, encoding: .utf8)
        else { return "\"\"" }
        return text
    }

    /// The channel answers `wake_up` only once the animation has finished, so
    /// there is no id to track and nothing to poll — see `runningMoveUUIDs`.
    public func wakeUp() async throws -> String {
        try await control.perform("wake_up")
        return ""
    }

    public func gotoSleep() async throws -> String {
        try await control.perform("goto_sleep")
        return ""
    }

    /// Empty, always, and not a guess: this connection never hands out a move id,
    /// so the set of moves it could be waiting on is empty by construction. That
    /// is what lets `RobotSession.waitForMoveToFinish` return at once instead of
    /// sitting out its whole timeout on a move that finished before it was told.
    public func runningMoveUUIDs() async throws -> Set<String> {
        []
    }

    public func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        try await control.perform(
            "set_motor_mode",
            payload: ["mode": .string(mode.rawValue)],
            correlation: .replyKey("motor_mode")
        )
    }

    public func volume() async throws -> AudioLevel {
        try await level(from: control.perform("get_volume", expecting: VolumeReply.self))
    }

    /// The daemon answers with the level it settled on, which is not the one asked
    /// for when the platform refused it — so the reply is read, not assumed.
    public func setVolume(_ percent: Int) async throws -> AudioLevel {
        try await level(from: control.perform(
            "set_volume",
            payload: ["volume": .number(Double(percent))],
            expecting: VolumeReply.self
        ))
    }

    public func microphoneVolume() async throws -> AudioLevel {
        try await level(from: control.perform("get_microphone_volume", expecting: VolumeReply.self))
    }

    public func setMicrophoneVolume(_ percent: Int) async throws -> AudioLevel {
        try await level(from: control.perform(
            "set_microphone_volume",
            payload: ["volume": .number(Double(percent))],
            expecting: VolumeReply.self
        ))
    }

    /// The channel reports a level and nothing else, where the REST route also
    /// names the sink it moved.
    private func level(from reply: VolumeReply) -> AudioLevel {
        AudioLevel(percent: reply.volume)
    }

    private struct VersionReply: Decodable {
        let version: String
    }

    private struct HardwareIDReply: Decodable {
        let hardwareID: String

        enum CodingKeys: String, CodingKey {
            case hardwareID = "hardware_id"
        }
    }

    private struct VolumeReply: Decodable {
        let volume: Int
    }

    /// `get_state` answers `{"state": {…}}` with no command echoed. Only the motor
    /// mode is read: the rest of that payload is the live pose, which arrives far
    /// more cheaply on the `subscribe_pose` broadcast.
    private struct StateReply: Decodable {
        let state: State

        struct State: Decodable {
            let motorMode: String

            enum CodingKeys: String, CodingKey {
                case motorMode = "motor_mode"
            }
        }
    }
}
