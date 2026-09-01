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
    /// Where the robot is now. Always a pose the platform can hold — see
    /// ``held(_:)``.
    public private(set) var pose: TeleopTarget
    /// Where it has been told to go, after the daemon's own clamps. Not clamped to
    /// the workspace: a robot told to go somewhere it cannot reach was still told,
    /// and the pose is what stops at the edge.
    public private(set) var goal: TeleopTarget
    /// Set when the walk has run into the edge of the workspace and stopped moving.
    /// Only ``isSettled`` reads it, and that is the whole point: a move whose goal
    /// the platform cannot reach would otherwise hold the slot for ever.
    private var isBlocked = false

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
        isBlocked = false
    }

    /// Walks the pose toward the goal.
    ///
    /// Through `TargetSlewLimiter`, which the app already uses to smooth what it
    /// *sends* a robot. Reusing it here is not laziness about the model: the thing
    /// being reproduced is how a head looks arriving at a target, and the client's
    /// own answer to that question is the one the joystick was tuned against.
    public mutating func advance(by seconds: Double) {
        guard seconds > 0 else { return }
        let stepped = slew.next(current: pose, goal: goal, dt: .seconds(seconds))
        // Named for what it is rather than `held`, which `redundantSelf` would strip
        // the `self.` off and leave calling a `TeleopTarget`.
        let reached = held(stepped)
        // Blocked, not merely clamped: sliding along the edge is still movement, and
        // a walk that is still travelling has not arrived. The threshold sits an
        // order below the smallest step the slew takes on its way into `isSettled`'s
        // own 1e-4 — at dt = 20 ms an error of 1e-4 still moves ~2·10⁻⁵ per tick.
        isBlocked = reached != stepped && Self.axisDifference(reached, pose) < Self.stallThreshold
        pose = reached
    }

    /// Whether the pose has arrived. What ends a "move": the daemon drops a move's
    /// UUID the instant its coroutine ends, and here the coroutine is the walk.
    ///
    /// A walk stopped at the workspace edge counts as arrived. It has to: the goal
    /// is what the robot was told, unreachable targets are ordinary — the height
    /// slider alone runs past the platform's 23 mm of lift — and a move that never
    /// settles is a move slot held for ever, which the session polls and reports as
    /// a robot permanently dancing.
    public var isSettled: Bool {
        Self.axisDifference(pose, goal) < 1e-4 || isBlocked
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

    /// The nearest pose along the way in from `target` that the platform can hold.
    ///
    /// **The bug this exists for is a head that comes off the robot.** The daemon's
    /// clamps say nothing about the Stewart platform's reach, and the controller's
    /// own sliders run past it — +30 mm of height against 23 mm of lift, and far
    /// less than that with any roll on top, because the workspace is coupled and
    /// not a box. A pose outside it left `StewartIK` with no answer, so a frame
    /// carried no `head_joints`, every crank fell back to zero, and the viewer drew
    /// the head where the pose said with the linkage standing at its zero
    /// configuration underneath: the shell open, the rods pointing at nothing.
    /// A real robot cannot do that — what it reports is where its motors are — so
    /// the simulator must not either.
    ///
    /// Interpolation is toward the platform at rest rather than per axis, for the
    /// same reason: the reachable set is **not** convex — the head reaches +23 mm
    /// with no rotation and 40° of roll with no lift, and neither halfway point is
    /// reachable — so clamping z against a fixed range would be wrong at every
    /// other angle. Rest is deep inside it, so the way in from anywhere crosses the
    /// boundary exactly once and a bisection finds it.
    func held(_ target: TeleopTarget) -> TeleopTarget {
        guard !canHold(target) else { return target }
        var (unreachable, reachable) = (1.0, 0.0)
        for _ in 0 ..< Self.reachSteps {
            let middle = (reachable + unreachable) / 2
            if canHold(Self.leaning(target, towardRest: middle)) {
                reachable = middle
            } else {
                unreachable = middle
            }
        }
        return Self.leaning(target, towardRest: reachable)
    }

    /// How many halvings the search above spends.
    ///
    /// Twenty rather than the ten that would place the head accurately enough to
    /// look right, because ``advance(by:)`` reads *changes* in the answer: two
    /// consecutive ticks land on the same boundary from slightly different targets,
    /// so the search's own resolution is noise on the movement it measures. At
    /// 2⁻²⁰ of a 30 mm command that noise is 30 nm, two orders under
    /// ``stallThreshold``; at 2⁻¹⁴ it would be 2 µm and swamp it.
    private static let reachSteps = 20

    /// Below this a step counts as no movement at all. See ``advance(by:)``.
    private static let stallThreshold = 1e-6

    /// A solve that lands inside every crank's limit. The body's own yaw is not
    /// part of the question — it is a joint of its own, already clamped above.
    private func canHold(_ target: TeleopTarget) -> Bool {
        ik.canHold(headPose: Self.headPose(of: target), bodyYaw: target.bodyYaw)
    }

    /// `target` with the head's offsets scaled toward the platform's rest pose:
    /// 1 is the target itself, 0 the head sitting square on a body that keeps
    /// whatever yaw it was given. Yaw leans toward `bodyYaw` rather than toward
    /// zero because that is what the platform sees — the daemon hands it
    /// `yaw − body_yaw`, so a head square to its own body is what "at rest" means.
    static func leaning(_ target: TeleopTarget, towardRest fraction: Double) -> TeleopTarget {
        var leaning = target
        leaning.x = target.x * fraction
        leaning.y = target.y * fraction
        leaning.z = target.z * fraction
        leaning.roll = target.roll * fraction
        leaning.pitch = target.pitch * fraction
        leaning.yaw = target.bodyYaw + (target.yaw - target.bodyYaw) * fraction
        return leaning
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
        let stewart = options.headJoints == true
            ? ik.solve(headPose: headPose, bodyYaw: pose.bodyYaw)
            : nil
        return RobotStateFrame(
            timestamp: timestamp,
            bodyYaw: options.bodyYaw != false ? pose.bodyYaw : nil,
            headJoints: stewart.map { [pose.bodyYaw] + $0 },
            // Wire order is `[right, left]`, which `RobotJointState.resolve` reads
            // back the same way round.
            antennas: options.antennaPositions != false ? [pose.antennaRight, pose.antennaLeft] : nil,
            headPose: options.headPose != false ? reportedHeadPose(headPose, options: options) : nil
        )
    }

    /// Whichever of the two shapes the stream asked for; both describe the same
    /// pose, and `use_pose_matrix` is what picks between them.
    private func reportedHeadPose(
        _ matrix: simd_double4x4,
        options: StateStreamOptions
    ) -> RobotStateFrame.HeadPose {
        options.poseAsMatrix == true
            ? .matrix(rowMajor(matrix))
            : .euler(
                x: pose.x, y: pose.y, z: pose.z,
                roll: pose.roll, pitch: pose.pitch, yaw: pose.yaw
            )
    }

    /// The pose as the daemon reports it: base frame, height offset already taken
    /// out, which is the frame `StewartIK` and `PassiveJointSolver` both expect.
    func headPoseMatrix() -> simd_double4x4 {
        Self.headPose(of: pose)
    }

    static func headPose(of target: TeleopTarget) -> simd_double4x4 {
        RigidTransform.transform(
            translation: SIMD3(target.x, target.y, target.z),
            rpy: SIMD3(target.roll, target.pitch, target.yaw)
        )
    }

    /// `head_pose.m` is sixteen values, row-major; `simd` stores columns.
    private func rowMajor(_ matrix: simd_double4x4) -> [Double] {
        (0 ..< 4).flatMap { row in (0 ..< 4).map { column in matrix[column][row] } }
    }
}
