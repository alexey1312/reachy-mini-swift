import Foundation
@testable import ReachyKit
import Testing

/// What a viewer draws, from what a frame happened to carry.
///
/// The daemon defaults `with_head_joints` to **false**, so "the frame has no motor
/// angles" is the ordinary case rather than the broken one — and the bug this suite
/// exists for is what the viewer did with it: every crank fell back to zero while
/// the head was placed from `head_pose`, which draws the head hanging off a linkage
/// standing 27 mm below it in its own zero configuration.
@Suite("Robot joint state")
struct RobotJointStateTests {
    private func platform() throws -> StewartIK {
        try StewartIK(geometry: RobotDescriptionFixture.geometry())
    }

    private func pose(z: Double = 0, roll: Double = 0, yaw: Double = 0) -> RobotStateFrame.HeadPose {
        .euler(x: 0, y: 0, z: z, roll: roll, pitch: 0, yaw: yaw)
    }

    @Test("a frame with no motor angles has them solved from the pose")
    func solvesTheCranksFromThePose() throws {
        let frame = RobotStateFrame(bodyYaw: 0, headPose: pose(z: 0.010, roll: 0.2))

        let state = try RobotJointState.resolve(frame, platform: platform())

        #expect(state.stewart.count == 6)
        let largest = state.stewart.map(abs).max() ?? 0
        #expect(largest > 1e-6, "the linkage was left at its zero configuration")
    }

    /// The commanded neutral is the one that looks settled and is not: `head_pose`
    /// zero is 27 mm above the URDF's zero configuration, so six zeros there is
    /// exactly the wrong answer and the easiest one to ship.
    @Test("the commanded neutral solves to the cranks a robot idles at")
    func neutralIsNotSixZeros() throws {
        let frame = RobotStateFrame(bodyYaw: 0, headPose: pose())

        let state = try RobotJointState.resolve(frame, platform: platform())

        for (leg, angle) in state.stewart.map({ $0 * 180 / .pi }).enumerated() {
            #expect(abs(abs(angle) - 35.9) < 0.05, "leg \(leg + 1) is \(angle)°")
        }
    }

    /// Body yaw has to be read before the solve, which subtracts it out — the daemon
    /// hands the platform `head_yaw − body_yaw`, so a head turned with its body is a
    /// platform that has not moved.
    @Test("body yaw is taken from the frame before the cranks are solved")
    func bodyYawReachesTheSolve() throws {
        let turned = RobotStateFrame(bodyYaw: Double.pi / 6, headPose: pose(yaw: .pi / 6))
        let rest = RobotStateFrame(bodyYaw: 0, headPose: pose())

        let solver = try platform()
        let turnedState = RobotJointState.resolve(turned, platform: solver)
        let restState = RobotJointState.resolve(rest, platform: solver)

        #expect(abs(turnedState.bodyYaw - .pi / 6) < 1e-12)
        for (leg, (a, b)) in zip(turnedState.stewart, restState.stewart).enumerated() {
            #expect(abs(a - b) < 1e-9, "leg \(leg + 1): \(a) vs \(b)")
        }
    }

    /// The angles the robot reported win: they are a measurement, and the solve is
    /// only what stands in for one.
    @Test("reported motor angles are used as they arrived")
    func reportedJointsWin() throws {
        let joints = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
        let frame = RobotStateFrame(bodyYaw: 0, headJoints: joints, headPose: pose(z: 0.010))

        let state = try RobotJointState.resolve(frame, platform: platform())

        #expect(state.bodyYaw == 0.1)
        #expect(state.stewart == Array(joints[1 ... 6]))
    }

    /// A pose outside the workspace has no solve at all, and the previous behaviour
    /// is the right one there: leave the cranks alone rather than invent an angle.
    /// Nothing produces such a frame any more — the simulator holds its pose inside
    /// the workspace and a robot reports where its motors are — so this is the
    /// belt-and-braces case, not a state the app renders.
    @Test("an unreachable pose leaves the cranks where they were")
    func unreachablePoseChangesNothing() throws {
        let frame = RobotStateFrame(bodyYaw: 0, headPose: pose(z: 0.060))

        let state = try RobotJointState.resolve(frame, platform: platform())

        #expect(state.stewart == RobotJointState.neutral.stewart)
    }
}
