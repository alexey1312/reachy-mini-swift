import Foundation
import simd

/// Live teleop over the data channel.
///
/// `set_full_target` carries head, antennas and body yaw in one message — the
/// same three things the LAN socket sends as one `FullBodyTarget`, where
/// `set_target` alone would need `set_body_yaw` and `set_antennas` beside it and
/// turn every frame into three.
///
/// It is *sent* rather than performed. The daemon does answer
/// `{"status":"ok","command":"set_full_target"}`, but at gesture rate a reply
/// budget would serialise each frame behind the previous one's answer, because
/// commands of one name take turns on this channel by design. The echo arrives
/// with no waiter registered and is dropped, which is what should happen to an
/// answer nobody is waiting on.
public actor RemoteTeleopChannel: TeleopChannel {
    private let control: RemoteControlChannel
    private let tickInterval: Duration
    private var limiter: TargetSlewLimiter
    private var pacerTask: Task<Void, Never>?
    private var goal = TeleopTarget()
    private var emitted = TeleopTarget()

    public init(
        control: RemoteControlChannel,
        tickInterval: Duration = .milliseconds(33),
        limiter: TargetSlewLimiter = TargetSlewLimiter()
    ) {
        self.control = control
        self.tickInterval = tickInterval
        self.limiter = limiter
    }

    deinit { pacerTask?.cancel() }

    /// Starts and stops only this target pacer. The underlying data channel belongs
    /// to the remote session, so leaving a controller must never close it.
    public func connect() {
        guard pacerTask == nil else { return }
        let interval = tickInterval
        pacerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    public func disconnect() async {
        let task = pacerTask
        pacerTask = nil
        task?.cancel()
        await task?.value
    }

    public func setLimiter(_ limiter: TargetSlewLimiter) {
        self.limiter = limiter
    }

    /// Stores the latest goal. One pacer walks toward it, so a peer gap can never
    /// accumulate one suspended task per gesture frame.
    public func send(_ target: TeleopTarget) {
        goal = target
    }

    /// Internal so transport tests can advance one deterministic frame without a
    /// duration-based assertion. Production calls it only from `pacerTask`.
    func tick() async {
        guard emitted != goal else { return }
        let next = limiter.next(current: emitted, goal: goal, dt: tickInterval)
        let frame = limiter.hasConverged(next, to: goal) ? goal : next
        guard await (try? control.sendIfOpen(
            "set_full_target",
            payload: Self.payload(for: frame)
        )) == true else { return }
        emitted = frame
    }

    /// The same pose the LAN route builds, expressed the way this channel wants
    /// it.
    ///
    /// `/api/move/ws/set_target` sends XYZRPY and the daemon composes the matrix
    /// itself with `R.from_euler("xyz", [roll, pitch, yaw])` — lowercase, so
    /// extrinsic, so `Rz(yaw)·Ry(pitch)·Rx(roll)`, which is exactly
    /// ``RigidTransform/rotation(rpy:)``. Here the matrix is composed on this side
    /// and flattened row by row, because `set_full_target` takes
    /// `np.array(cmd.head).reshape(4, 4)`.
    ///
    /// The daemon's pair is `[right, left]`; the Swift target names both physical
    /// sides, so the wire order is explicit here and on the LAN route.
    static func payload(for target: TeleopTarget) -> [String: RemoteValue] {
        let pose = RigidTransform.transform(
            translation: SIMD3(target.x, target.y, target.z),
            rpy: SIMD3(target.roll, target.pitch, target.yaw)
        )
        return [
            "head": .array(RigidTransform.rowMajorValues(pose).map(RemoteValue.number)),
            "antennas": .array([.number(target.antennaRight), .number(target.antennaLeft)]),
            "body_yaw": .number(target.bodyYaw),
        ]
    }
}

extension RemoteRobotConnection: TeleopClient {
    public nonisolated func makeTeleop() throws -> any TeleopChannel {
        RemoteTeleopChannel(control: control)
    }
}
