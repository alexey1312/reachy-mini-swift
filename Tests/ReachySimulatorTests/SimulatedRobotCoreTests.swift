import Foundation
import ReachyKit
@testable import ReachySimulator
import Testing

/// The arithmetic a simulator has to get right, with no socket in the way.
///
/// The clamps are the part that matters most: `.claude/rules/daemon-api.md` records
/// them from `inverse_kinematics_safe`, and the first of them **bites silently** —
/// a simulator that skipped it would make the joystick feel different from the
/// robot and give nobody a reason why.
@Suite("Simulated robot core")
struct SimulatedRobotCoreTests {
    /// Built from the bundled description rather than a toy: the platform's
    /// dimensions are what the solve depends on. `ReachyKitTests` has a fixture of
    /// its own for the same reason — one test target cannot import another's
    /// sources, so the two lines live twice rather than in a shared target nothing
    /// else would use.
    private func core() throws -> SimulatedRobotCore {
        let urdf = try URDFParser.parse(BundledRobotGeometry().urdf())
        return try SimulatedRobotCore(geometry: #require(StewartGeometry(urdf: urdf)))
    }

    private func degrees(_ radians: Double) -> Double {
        radians * 180 / .pi
    }

    private func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }

    // MARK: - The daemon's clamps

    /// Recorded: "commanding `body_yaw = 180°` with the head left at world zero
    /// turns the body **65°** and reports nothing." Asserted as a magnitude because
    /// 180° is the wrap boundary itself and lands on −180° here.
    @Test("a body yaw the head cannot follow is pulled to 65 degrees")
    func relativeYawClampBites() {
        let clamped = SimulatedRobotCore.clamped(TeleopTarget(yaw: 0, bodyYaw: .pi))

        #expect(abs(abs(degrees(clamped.bodyYaw)) - 65) < 1e-9)
        #expect(clamped.yaw == 0)
    }

    /// The same rule from the other side, and the behaviour `automatic_body_yaw`
    /// names: it defaults to true, has no HTTP route to switch off, and so applies
    /// to every path this client has.
    @Test("a large head yaw raises body yaw on its own")
    func largeHeadYawDragsTheBody() {
        let clamped = SimulatedRobotCore.clamped(TeleopTarget(yaw: radians(90), bodyYaw: 0))

        #expect(abs(degrees(clamped.bodyYaw) - 25) < 1e-9)
    }

    /// `max_body_yaw`, applied after the relative clamp so a body dragged out by a
    /// far-turned head still stops at the limit.
    @Test("body yaw stops at 160 degrees however far the head has turned")
    func bodyYawStopsAtItsLimit() {
        let clamped = SimulatedRobotCore.clamped(TeleopTarget(yaw: radians(179), bodyYaw: radians(179)))

        #expect(abs(degrees(clamped.bodyYaw) - 160) < 1e-9)
    }

    /// Recorded: angles must arrive pre-wrapped to `[-π, π]`. Head and body are
    /// given the same 200° so the relative clamp has nothing to do and the wrap is
    /// the only thing under test.
    @Test("angles wrap into [-pi, pi] rather than running on")
    func anglesWrap() {
        let clamped = SimulatedRobotCore.clamped(
            TeleopTarget(yaw: radians(200), bodyYaw: radians(200))
        )

        #expect(abs(degrees(clamped.yaw) - -160) < 1e-9)
        #expect(abs(degrees(clamped.bodyYaw) - -160) < 1e-9)
    }

    // MARK: - Where it starts, and how it gets anywhere

    /// Zeros, because that is what a robot idles at: the client's neutral is
    /// `TeleopTarget()` and `gotoNeutral` sends the same. Not the URDF's zero
    /// configuration, which is 27 mm lower and is only where rod lengths are
    /// measured.
    @Test("a fresh robot sits at the commanded neutral")
    func startsAtNeutral() throws {
        let core = try core()

        #expect(core.pose == TeleopTarget())
        #expect(core.goal == TeleopTarget())
    }

    @Test("the pose walks to the goal and settles there")
    func advancesTowardTheGoal() throws {
        var core = try core()
        core.aim(at: TeleopTarget(pitch: radians(15), bodyYaw: radians(20)))
        let goal = core.goal

        let midway = { () -> TeleopTarget in
            var stepped = core
            stepped.advance(by: 0.05)
            return stepped.pose
        }()
        #expect(midway != TeleopTarget(), "nothing moved in the first step")

        for _ in 0 ..< 200 {
            core.advance(by: 0.05)
        }

        #expect(abs(core.pose.pitch - goal.pitch) < 1e-4)
        #expect(abs(core.pose.bodyYaw - goal.bodyYaw) < 1e-4)
    }

    // MARK: - The edge of the workspace, which is where the head used to come off

    /// **The reported bug.** The controller's height slider runs to 30 mm and the
    /// platform lifts 23; past that `StewartIK` has no answer, so the frame carried
    /// no `head_joints`, the viewer posed every crank at zero and drew the head
    /// where `head_pose` said — a head floating over an open shell. A robot reports
    /// where its motors are, so a simulated one has to stop at the edge instead.
    @Test("a height the platform cannot lift to stops at the edge")
    func unreachableHeightStopsShort() throws {
        var core = try core()
        core.aim(at: TeleopTarget(z: 0.030))

        for _ in 0 ..< 400 {
            core.advance(by: 0.02)
        }

        #expect(core.pose.z < 0.024, "the head went past the platform's reach")
        #expect(core.pose.z > 0.020, "the head stopped well short of the reach it has")
    }

    /// Every pose the walk passes through, not only where it ends up. The two
    /// halves of the reported combination — 28 mm of height and −40° of roll — are
    /// each reachable on their own and neither halfway point is, because the
    /// workspace is coupled: a clamp per axis would pass this test's endpoints and
    /// fail every frame in between.
    @Test("every pose along the way carries the motor angles that draw it")
    func everyFrameIsDrawable() throws {
        var core = try core()
        core.aim(at: TeleopTarget(z: 0.028, roll: radians(-40), bodyYaw: radians(30)))

        for step in 0 ..< 400 {
            core.advance(by: 0.02)
            let frame = core.frame(at: Date(timeIntervalSince1970: 0), options: .visualization)
            #expect(frame.headJoints?.count == 7, "step \(step) has no linkage to draw")
        }
    }

    /// A goal outside the workspace is ordinary — the sliders reach one — and the
    /// walk toward it has to end anyway: `isSettled` is what drops a move's UUID,
    /// and a move that never settles is a move slot held for ever.
    @Test("a walk that runs into the edge still settles")
    func blockedWalkSettles() throws {
        var core = try core()
        core.aim(at: TeleopTarget(z: 0.030))

        for _ in 0 ..< 400 {
            core.advance(by: 0.02)
        }

        #expect(core.isSettled)
        #expect(core.pose.z < core.goal.z, "the goal was reached after all — pick a further one")
    }

    /// The goal stays what the robot was told. Only the pose is bounded by what the
    /// platform can hold, which is the same split a real daemon has: it takes the
    /// target, and its motors are where they are.
    @Test("the goal keeps the commanded height, however unreachable")
    func theGoalIsNotClamped() throws {
        var core = try core()

        core.aim(at: TeleopTarget(z: 0.030))

        #expect(core.goal.z == 0.030)
    }

    @Test("a zero step moves nothing")
    func zeroStepIsInert() throws {
        var core = try core()
        core.aim(at: TeleopTarget(yaw: radians(10)))

        core.advance(by: 0)

        #expect(core.pose == TeleopTarget())
    }

    // MARK: - What a frame carries

    /// `.visualization` asks for the motor angles and a matrix pose so no Euler
    /// convention has to be guessed; `head_joints` is `[body_yaw, stewart_1…6]`.
    @Test("a visualization frame carries seven joints and a matrix pose")
    func visualizationFrameIsComplete() throws {
        var core = try core()
        core.aim(at: TeleopTarget(pitch: radians(10), bodyYaw: radians(15)))
        for _ in 0 ..< 200 {
            core.advance(by: 0.05)
        }

        let frame = core.frame(at: Date(timeIntervalSince1970: 0), options: .visualization)

        let joints = try #require(frame.headJoints)
        #expect(joints.count == 7)
        #expect(abs(joints[0] - core.pose.bodyYaw) < 1e-12)
        #expect(frame.bodyYaw != nil)
        #expect(try #require(frame.antennas).count == 2)
        guard case let .matrix(values) = try #require(frame.headPose) else {
            Issue.record("visualization asks for a matrix pose")
            return
        }
        #expect(values.count == 16)
    }

    /// `.hearing` names every geometry flag `false` on purpose — a two-field
    /// indicator must not drag a full pose behind it. A simulator that answered
    /// everything regardless would make that measurement meaningless.
    @Test("a hearing frame carries none of the geometry")
    func hearingFrameIsEmpty() throws {
        let core = try core()

        let frame = core.frame(at: Date(timeIntervalSince1970: 0), options: .hearing)

        #expect(frame.headPose == nil)
        #expect(frame.headJoints == nil)
        #expect(frame.bodyYaw == nil)
        #expect(frame.antennas == nil)
    }

    /// Two absences that are answers rather than gaps: only a Placo-backed daemon
    /// computes passive joints, and there are no microphones to hear with.
    @Test("passive joints are never reported, as the default engine never has them")
    func passiveJointsStayAbsent() throws {
        let core = try core()

        #expect(core.frame(at: Date(), options: .visualization).passiveJoints == nil)
    }

    /// Wire order is `[right, left]`, which is what `RobotJointState.resolve` reads
    /// back — crossing them here would put the antennas on the wrong sides in the
    /// 3D view and nowhere else.
    @Test("antennas are reported right-first, the way the wire carries them")
    func antennasAreInWireOrder() throws {
        var core = try core()
        core.aim(at: TeleopTarget(antennaLeft: radians(30), antennaRight: radians(-10)))
        for _ in 0 ..< 200 {
            core.advance(by: 0.05)
        }

        let antennas = try #require(core.frame(at: Date(), options: .visualization).antennas)

        #expect(abs(antennas[0] - core.pose.antennaRight) < 1e-12)
        #expect(abs(antennas[1] - core.pose.antennaLeft) < 1e-12)
    }
}
