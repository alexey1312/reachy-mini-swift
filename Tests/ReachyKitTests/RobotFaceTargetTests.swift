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
}
