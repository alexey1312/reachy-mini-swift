import Foundation
import ReachyKit
import simd

/// Where the simulated robot is, and how it gets where it is told — as a value.
///
/// No physics, which is the parity target: upstream's own `--mockup-sim` is
/// described as behaving "exactly like a real robot for apps" without simulating
/// any. So this holds a pose, walks it toward the commanded one, and reports it.
/// Everything that could be a value is one, because the arithmetic is the part
/// worth testing and a socket around it proves nothing about it.
public struct SimulatedRobotCore: Sendable {
    /// Where the robot is now.
    public private(set) var pose: TeleopTarget
    /// Where it has been told to go, after the daemon's own clamps.
    public private(set) var goal: TeleopTarget

    private let geometry: StewartGeometry
    private let ik: StewartIK
    private let slew: TargetSlewLimiter

    /// `|head_yaw − body_yaw| ≤ 65°` — `max_relative_yaw`, clamped silently.
    static let maxRelativeYaw = 65 * Double.pi / 180
    /// `|body_yaw| ≤ 160°` — `max_body_yaw`, matching the URDF's `yaw_body` limit
    /// of ±2.79253 rad.
    static let maxBodyYaw = 160 * Double.pi / 180

    public init(geometry: StewartGeometry, slew: TargetSlewLimiter = .init()) {
        self.geometry = geometry
        ik = StewartIK(geometry: geometry)
        self.slew = slew
        // Zeros, because that is what a robot idles at: the client's neutral is
        // `TeleopTarget()` and `gotoNeutral` sends the same. Not the URDF's zero
        // configuration, which sits 27 mm lower — see `StewartGeometry.restHeadPoseZ`.
        pose = TeleopTarget()
        goal = TeleopTarget()
    }

    /// Takes a target the way the daemon does, clamps included.
    public mutating func aim(at target: TeleopTarget) {
        goal = Self.clamped(target)
    }

    /// Walks the pose toward the goal.
    ///
    /// Through `TargetSlewLimiter`, which the app already uses to smooth what it
    /// *sends* a robot. Reusing it here is not laziness about the model: the thing
    /// being reproduced is how a head looks arriving at a target, and the client's
    /// own answer to that question is the one the joystick was tuned against.
    public mutating func advance(by seconds: Double) {
        guard seconds > 0 else { return }
        pose = slew.next(current: pose, goal: goal, dt: .seconds(seconds))
    }

    /// Whether the pose has arrived. What ends a "move": the daemon drops a move's
    /// UUID the instant its coroutine ends, and here the coroutine is the walk.
    public var isSettled: Bool {
        Self.axisDifference(pose, goal) < 1e-4
    }

    static func axisDifference(_ lhs: TeleopTarget, _ rhs: TeleopTarget) -> Double {
        max(
            max(abs(lhs.x - rhs.x), max(abs(lhs.y - rhs.y), abs(lhs.z - rhs.z))),
            max(
                max(abs(lhs.roll - rhs.roll), max(abs(lhs.pitch - rhs.pitch), abs(lhs.yaw - rhs.yaw))),
                max(
                    abs(lhs.bodyYaw - rhs.bodyYaw),
                    max(abs(lhs.antennaLeft - rhs.antennaLeft), abs(lhs.antennaRight - rhs.antennaRight))
                )
            )
        )
    }

    /// The daemon's three rules on a target, in the order it applies them.
    ///
    /// Recorded in `.claude/rules/daemon-api.md` from `inverse_kinematics_safe`,
    /// and the first of them **bites silently** — which is exactly why a simulator
    /// that skipped it would make the joystick feel different from the robot and
    /// give no sign of why.
    ///
    /// 1. Angles arrive pre-wrapped to `[-π, π]`: `body_yaw = 200°` comes out −95°.
    /// 2. Body yaw is pulled to within 65° of the head, which is one rule serving
    ///    two behaviours — commanding `body_yaw = 180°` with the head at zero turns
    ///    the body 65°, and a large head yaw *raises* body yaw on its own. The
    ///    second is `automatic_body_yaw`, which defaults to true and has no HTTP
    ///    route to switch off, so every path this client has gets it.
    /// 3. `|body_yaw| ≤ 160°`, applied after, so a body dragged out by a far-turned
    ///    head still stops at the limit.
    public static func clamped(_ target: TeleopTarget) -> TeleopTarget {
        var clamped = target
        clamped.roll = wrapped(target.roll)
        clamped.pitch = wrapped(target.pitch)
        clamped.yaw = wrapped(target.yaw)
        clamped.bodyYaw = wrapped(target.bodyYaw)
        clamped.bodyYaw = min(
            max(clamped.bodyYaw, clamped.yaw - maxRelativeYaw),
            clamped.yaw + maxRelativeYaw
        )
        clamped.bodyYaw = min(max(clamped.bodyYaw, -maxBodyYaw), maxBodyYaw)
        return clamped
    }

    /// To `[-π, π]`, the range the daemon says angles must arrive in.
    static func wrapped(_ angle: Double) -> Double {
        let turn = 2 * Double.pi
        let shifted = (angle + .pi).truncatingRemainder(dividingBy: turn)
        return (shifted < 0 ? shifted + turn : shifted) - .pi
    }

    /// One state-stream frame, carrying exactly what was asked for.
    ///
    /// Honouring the options is not politeness: `.hearing` names every geometry
    /// flag `false` precisely so a two-field indicator does not drag a full pose
    /// behind it, and a simulator that answered everything regardless would make
    /// that measurement meaningless.
    ///
    /// `passiveJoints` is always nil, which is the truthful answer rather than a
    /// gap: only a Placo-backed daemon computes them, the default engine never
    /// does, and `RobotJointState.resolve` falls through to solving them here.
    /// `directionOfArrival` likewise — there are no microphones to hear with, and
    /// `DirectionOfArrivalModel` reads a null reading as "no array" already.
    public func frame(at timestamp: Date, options: StateStreamOptions) -> RobotStateFrame {
        let headPose = headPoseMatrix()
        var frame = RobotStateFrame(timestamp: timestamp)
        if options.bodyYaw != false {
            frame.bodyYaw = pose.bodyYaw
        }
        if options.headJoints == true, let stewart = ik.solve(headPose: headPose, bodyYaw: pose.bodyYaw) {
            frame.headJoints = [pose.bodyYaw] + stewart
        }
        if options.antennaPositions != false {
            // Wire order is `[right, left]`, which `RobotJointState.resolve` reads
            // back the same way round.
            frame.antennas = [pose.antennaRight, pose.antennaLeft]
        }
        if options.headPose != false {
            frame.headPose = options.poseAsMatrix == true
                ? .matrix(rowMajor(headPose))
                : .euler(
                    x: pose.x, y: pose.y, z: pose.z,
                    roll: pose.roll, pitch: pose.pitch, yaw: pose.yaw
                )
        }
        return frame
    }

    /// The pose as the daemon reports it: base frame, height offset already taken
    /// out, which is the frame `StewartIK` and `PassiveJointSolver` both expect.
    func headPoseMatrix() -> simd_double4x4 {
        RigidTransform.transform(
            translation: SIMD3(pose.x, pose.y, pose.z),
            rpy: SIMD3(pose.roll, pose.pitch, pose.yaw)
        )
    }

    /// `head_pose.m` is sixteen values, row-major; `simd` stores columns.
    private func rowMajor(_ matrix: simd_double4x4) -> [Double] {
        (0 ..< 4).flatMap { row in (0 ..< 4).map { column in matrix[column][row] } }
    }
}
