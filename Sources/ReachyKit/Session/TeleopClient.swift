import Foundation

/// A connection that can be driven live.
///
/// Both transports can, and they carry the same pose in two different shapes —
/// the LAN socket as XYZRPY, the data channel as a flattened 4×4 matrix. The
/// screens above this see neither.
public protocol TeleopClient: Sendable {
    func makeTeleop() throws -> any TeleopChannel
}

/// One open teleop stream.
///
/// `connect` and `disconnect` mean genuinely different things on the two
/// transports — a WebSocket to open on one, a channel that was already open long
/// before a joystick existed on the other — which is why they are on the protocol
/// rather than assumed away.
public protocol TeleopChannel: Sendable {
    func connect() async
    func send(_ target: TeleopTarget) async
    func disconnect() async
}

/// A live-teleop target: head pose offsets from neutral in metres and radians,
/// plus body yaw and the two physically named antennas. Both transports encode
/// them in the daemon's `[right, left]` wire order. The daemon clamps every safety
/// limit server-side and ignores targets while a recorded move is running.
///
/// **The head pose is measured from the base, not from the body.** `bodyYaw` is a
/// joint of its own and does not carry the head with it — the daemon hands the
/// Stewart platform `yaw − bodyYaw`, so a head that should keep facing the way the
/// body points has to have `bodyYaw` added into `yaw` by whoever composes the two
/// (`TeleopDriver`). `RobotStateFrame.headPose` reports the same frame, and
/// `PassiveJointSolver` subtracts `bodyYaw` for exactly this reason.
///
/// Named here rather than inside `SetTargetClient` because two transports carry
/// it now; the alias on that type keeps every existing call site compiling.
/// `Codable` because a recorded move is a list of these on disk. That makes the
/// property names part of `JSONCodec.stored`'s frozen format: renaming one silently
/// drops that axis from every recording a shipped build wrote.
public struct TeleopTarget: Sendable, Equatable, Codable {
    public var x, y, z, roll, pitch, yaw: Double
    public var bodyYaw: Double
    public var antennaLeft: Double
    public var antennaRight: Double

    public init(
        x: Double = 0, y: Double = 0, z: Double = 0,
        roll: Double = 0, pitch: Double = 0, yaw: Double = 0,
        bodyYaw: Double = 0, antennaLeft: Double = 0, antennaRight: Double = 0
    ) {
        self.x = x
        self.y = y
        self.z = z
        self.roll = roll
        self.pitch = pitch
        self.yaw = yaw
        self.bodyYaw = bodyYaw
        self.antennaLeft = antennaLeft
        self.antennaRight = antennaRight
    }
}

public extension RobotSession {
    var canTeleoperate: Bool {
        client is any TeleopClient
    }

    func makeTeleop() throws -> any TeleopChannel {
        guard let client else { throw ReachyKitError.notConnected }
        guard let teleop = client as? any TeleopClient else {
            throw ReachyKitError.teleopUnavailable
        }
        return try teleop.makeTeleop()
    }
}
