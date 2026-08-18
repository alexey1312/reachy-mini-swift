import Foundation
import ReachyKit
@testable import ReachySimulator
import Testing

/// The loop around the core. The arithmetic is asserted next door, without a
/// clock; what is left here is whether frames actually arrive and stop arriving.
@Suite("Simulated robot stream", .timeLimit(.minutes(1)))
struct SimulatedRobotTests {
    private func robot(tick: Duration = .milliseconds(5)) throws -> SimulatedRobot {
        let urdf = try URDFParser.parse(BundledRobotGeometry().urdf())
        return try SimulatedRobot(geometry: #require(StewartGeometry(urdf: urdf)), tick: tick)
    }

    /// Counted rather than timed. A rate assertion would be a duration assertion on
    /// a loaded runner, and the thing worth knowing is that the loop runs at all and
    /// that what it publishes is the pose actually moving.
    @Test("a subscriber receives frames while the pose walks to its goal")
    func publishesMovingFrames() async throws {
        let robot = try robot()
        // Far enough that five frames at 20 Hz cannot reach it: the slew limiter
        // turns the body at 120°/s, so a 57° goal is still moving a quarter of a
        // second in, which is what makes the monotonicity below meaningful.
        robot.aim(at: TeleopTarget(pitch: 0.2, bodyYaw: 1.0))

        var poses: [Double] = []
        for await update in robot.updates(.visualization) {
            let joints = try #require(update.frame?.headJoints)
            #expect(joints.count == 7)
            try poses.append(#require(update.frame?.bodyYaw))
            if poses.count >= 5 {
                break
            }
        }
        robot.stop()

        #expect(poses.count == 5)
        // Monotone toward the goal, which is what says the frames are samples of
        // one moving robot rather than five copies of a static pose.
        #expect(zip(poses, poses.dropFirst()).allSatisfy { $0 < $1 })
        #expect(robot.pose.bodyYaw > 0)
    }

    /// Ending the iteration is what unsubscribes — `onTermination` — and the loop
    /// stops with the last subscriber. Asserted by the fact that a second
    /// subscription still works afterwards, which it would not if the loop had been
    /// left cancelled.
    @Test("the loop restarts for a later subscriber")
    func loopRestartsAfterTheLastSubscriberLeaves() async throws {
        let robot = try robot()

        for await _ in robot.updates(.visualization) {
            break
        }
        robot.aim(at: TeleopTarget(yaw: 0.1))
        for await _ in robot.updates(.visualization) {
            break
        }

        robot.stop()
    }

    /// `stop()` finishes every stream, so an iteration parked on the next frame
    /// returns. The suite's time limit is the assertion: without the finish this
    /// never completes.
    @Test("stop ends a subscription that is waiting for its next frame")
    func stopEndsAWaitingSubscription() async throws {
        let robot = try robot(tick: .seconds(30))
        let stream = robot.updates(.visualization)
        let drained = Task {
            for await _ in stream {}
            return true
        }

        robot.stop()

        #expect(await drained.value)
    }
}
