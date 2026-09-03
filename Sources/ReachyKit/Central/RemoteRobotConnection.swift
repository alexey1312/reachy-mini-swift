import Foundation
import ReachyJSON

/// The daemon, reached over a WebRTC session instead of over HTTP.
///
/// Deliberately a `RobotAPIClient` like `RobotConnection`, so `RobotSession` and
/// the screens above it do not have to know which way the robot was reached. It
/// is an honest subset, not a facade: everything the data channel does not carry
/// is left on the protocol's throwing defaults rather than stubbed out. URDF,
/// kinematics and `/wifi`, `/update` are HTTP-only, and asking for them here
/// fails rather than lies.
///
/// The command names and their fields are `reachy_mini/io/protocol.py`; the reply
/// shapes are `process_command` in `daemon/backend/abstract.py`.
public actor RemoteRobotConnection: RobotAPIClient, RobotUnlinkClient, MovePlaybackClient {
    let control: RemoteControlChannel
    /// From the central listing that got us to this robot — the same place the
    /// user picked it from. Daemon 1.10.0 also answers `get_robot_name`, but the
    /// listing is already in hand and costs no round trip.
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
            // The HTTP route this reports on is unreachable here. `set_robot_name`
            // on the data channel is the other half of the answer, and
            // `RobotSession` reads it off the `RobotRenameClient` conformance.
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
        } catch let error as RemoteControlChannel.Failure {
            // `.closed` is the poll's proof the relay died and has to escape. So
            // does `.rpc`, and it cannot arise here anyway: `get_state` goes through
            // `perform`, whose `throwIfError` reads the `{"error": "…"}` string shape
            // and has no code to carry — only `call`'s JSON-RPC path produces `.rpc`.
            guard case .robot = error else { throw error }
            // `.robot` is the robot saying something is wrong, and it used to vanish
            // here — an unknown motor mode reads as a robot asleep, which disables
            // teleop, moves and the viewport with nothing said anywhere.
            _ = RobotSession.message(for: error)
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
        else {
            // Only reachable for a string `JSONEncoder` cannot encode, which is not
            // a thing a name can be. Empty rather than a placeholder: an invented
            // name would be shown as the robot's own.
            return "\"\""
        }
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

    // MARK: Recorded moves

    //
    // **The handles here are this app's, not the daemon's.** `play_recorded_move`
    // is fire-and-forget: the ack means "dispatched", and nothing comes back to
    // name the run. `stop_move` needs no name either — it interrupts whatever is
    // playing, whoever started it. So a handle is minted here to answer the one
    // question the session asks with it, "is the thing I started still going", and
    // it is never sent anywhere. `is_move_running` is what answers it, and it says
    // *whether*, never *which*.

    /// The handle for the run this connection dispatched, while it is still going.
    ///
    /// One slot, written by both `playMove` and `gotoNeutral`, so parking replaces
    /// a dance's handle — and `stopMove` clears whichever is there, since the
    /// command it sends stops whatever is playing anyway.
    private var playbackHandle: String?

    /// No index route on this channel: the library comes off what this app kept
    /// from the robot's own network. See ``MovePlaybackClient/offersMoveIndex``.
    public nonisolated var offersMoveIndex: Bool {
        false
    }

    /// The one place this transport is *ahead* of the HTTP one: a play there
    /// blocks until the dataset is on the robot, while `play_recorded_move` is
    /// fire-and-forget and would simply take a long time to start moving. Warming
    /// first turns that into a wait the user does not sit through.
    public func preload(dataset: String) async throws {
        try await control.perform("preload_dataset", payload: ["dataset_name": .string(dataset)])
    }

    public func playMove(dataset: String, move: String) async throws -> String {
        try await control.perform("play_recorded_move", payload: [
            "move_name": .string(move),
            "dataset_name": .string(dataset),
        ])
        let handle = UUID().uuidString
        playbackHandle = handle
        return handle
    }

    /// The handle this connection dispatched, while the robot reports a move
    /// running. Empty otherwise — including for a handle from a previous launch,
    /// which nothing here can recognise.
    public func runningMoveUUIDs() async throws -> Set<String> {
        guard let handle = playbackHandle else { return [] }
        let running = try await control.perform(
            "get_state",
            correlation: .replyKey("state"),
            expecting: StateReply.self
        ).state.isMoveRunning
        // The `await` above is a suspension point, and this is an actor: `stopMove`
        // and `playMove` both run inside it. Answering for a handle that has since
        // been replaced would clear the new dance's handle and let its monitor
        // count two misses while the robot is still moving.
        guard playbackHandle == handle else { return [] }
        // `nil` is a daemon that cannot say, which is not "not running": treating
        // the two alike ends playback the instant it starts.
        guard let running else { return [handle] }
        if !running {
            playbackHandle = nil
        }
        return running ? [handle] : []
    }

    /// Stops whatever is playing. The handle is not sent — there is nowhere to send
    /// it — so this stops a move somebody else started too, which is what the
    /// command does and what the session wants of it.
    public func stopMove(uuid _: String) async throws {
        try await control.perform("stop_move", correlation: .replyKey("stopped"))
        playbackHandle = nil
    }

    /// Walks the head, body and antennas back to the pose `gotoNeutral` sends over
    /// HTTP — the same numbers, since the neutral is the robot's, not the route's.
    public func gotoNeutral(duration: TimeInterval) async throws -> String {
        try await control.perform("goto_target", payload: [
            "head": .array([.number(0), .number(0), .number(0), .number(0), .number(0), .number(0)]),
            "antennas": .array([.number(-0.1745), .number(0.1745)]),
            "body_yaw": .number(0),
            "duration": .number(duration),
        ])
        let handle = UUID().uuidString
        playbackHandle = handle
        return handle
    }

    /// Nothing to send: `stop_move` silences the move's own sound as it interrupts
    /// it, so by the time this is reached the player is already quiet.
    public func stopSound() async throws {}

    /// One pose reading, for a viewer that has no socket to open.
    ///
    /// Nil where the robot sent no pose at all, which is a robot with its backend
    /// down rather than an error to report — see ``RemoteStateSnapshot/frame``.
    public func stateFrame() async throws -> RobotStateFrame? {
        try await control.perform(
            "get_state",
            correlation: .replyKey("state"),
            expecting: StateReply.self
        ).state.snapshot.frame
    }

    public func deleteHFToken() async throws {
        try await control.perform("delete_hf_token")
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

    /// `get_state` answers `{"state": {…}}` with no command echoed. The pose half
    /// is ``RemoteStateSnapshot``, the same type the pushed frames carry, so the
    /// polled path cannot drift from the pushed one — it used to, and that is why
    /// the hearing indicator was missing from it.
    private struct StateReply: Decodable {
        let state: State

        struct State: Decodable {
            let motorMode: String
            /// Whether the daemon is running a move task — any move task, with no
            /// way to ask which. That is the whole of what this transport can say
            /// about playback, and what `runningMoveUUIDs` is built on.
            let isMoveRunning: Bool?
            let snapshot: RemoteStateSnapshot

            enum CodingKeys: String, CodingKey {
                case motorMode = "motor_mode"
                case isMoveRunning = "is_move_running"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                motorMode = try container.decode(String.self, forKey: .motorMode)
                isMoveRunning = try container.decodeIfPresent(Bool.self, forKey: .isMoveRunning)
                snapshot = try RemoteStateSnapshot(from: decoder)
            }
        }
    }
}
