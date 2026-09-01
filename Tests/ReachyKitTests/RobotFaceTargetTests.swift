@testable import ReachyKit
import Testing

/// The route answers an untyped object, so every field here is read out of a
/// dictionary rather than decoded — and JSON numbers arrive as whichever Swift type
/// their value fits.
@Suite("RobotFaceTarget")
struct RobotFaceTargetTests {
    @Test("a detected face carries its point")
    func detected() {
        let target = RobotFaceTarget.decoded(from: ["detected": true, "x": 0.25, "y": -0.5, "roll": 0.1])
        #expect(target == RobotFaceTarget(x: 0.25, y: -0.5, roll: 0.1))
    }

    /// A face dead centre decodes its coordinates as `Int`, which is the shape that
    /// blanks a field which read correctly all day.
    @Test("whole numbers read the same as fractional ones")
    func wholeNumbers() {
        let target = RobotFaceTarget.decoded(from: ["detected": true, "x": 0, "y": 1, "roll": 0])
        #expect(target == RobotFaceTarget(x: 0, y: 1, roll: 0))
    }

    @Test("roll is optional; the point is not")
    func partialPayloads() {
        #expect(RobotFaceTarget.decoded(from: ["detected": true, "x": 0.1, "y": 0.2])?.roll == 0)
        #expect(RobotFaceTarget.decoded(from: ["detected": true, "y": 0.2]) == nil)
    }

    /// The daemon leaves the last aim in place between detections, so a point without
    /// `detected` behind it is stale rather than current.
    @Test("nothing detected is nothing reported", arguments: [
        ["detected": false, "x": 0.4, "y": 0.4] as [String: any Sendable],
        ["x": 0.4, "y": 0.4],
        [:],
    ])
    func undetected(payload: [String: any Sendable]) {
        #expect(RobotFaceTarget.decoded(from: payload) == nil)
    }

    /// What the robot actually sends, measured on a Wireless unit running daemon
    /// 1.10.0: the target is nested under `face_target`, beside a `status`. Reading
    /// the top level found nothing and reported an empty room for ever.
    @Test("the reading is taken from where the robot puts it")
    func readsTheNestedTarget() {
        let payload: [String: any Sendable] = [
            "status": "ok",
            "face_target": ["detected": true, "x": -0.3, "y": 0.2, "roll": 0.05] as [String: any Sendable],
        ]
        #expect(RobotFaceTarget.decoded(from: payload) == RobotFaceTarget(x: -0.3, y: 0.2, roll: 0.05))
    }

    @Test("an empty room stays empty")
    func readsTheNestedAbsence() {
        let payload: [String: any Sendable] = [
            "status": "ok",
            "face_target": ["detected": false, "x": nil, "y": nil] as [String: (any Sendable)?],
        ]
        #expect(RobotFaceTarget.decoded(from: payload) == nil)
    }
}
