import Foundation
import ReachyJSON
@testable import ReachyKit
import Testing

@Suite("Robot state frame decoding")
struct RobotStateFrameTests {
    private func decode(_ json: String) throws -> RobotStateFrame {
        try JSONCodec.daemon.decode(RobotStateFrame.self, from: Data(json.utf8))
    }

    @Test("matrix pose survives the round trip to a transform")
    func matrixPose() throws {
        let frame = try decode(#"""
        {"head_pose": {"m": [1,0,0,0.01, 0,1,0,0.02, 0,0,1,0.177, 0,0,0,1]},
         "head_joints": [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7],
         "body_yaw": 0.25, "antennas_position": [0.1, -0.1], "passive_joints": null}
        """#)
        #expect(frame.headJoints?.count == 7)
        #expect(frame.bodyYaw == 0.25)
        #expect(frame.passiveJoints == nil)
        let transform = try #require(frame.headPose?.transform)
        // Row-major input: translation is the last column, not the last row.
        #expect(abs(transform.translation.z - 0.177) < 1e-12)
        #expect(abs(transform.translation.x - 0.01) < 1e-12)
    }

    @Test("euler pose is accepted when the stream is not in matrix mode")
    func eulerPose() throws {
        let frame = try decode(#"""
        {"head_pose": {"x": 0.0, "y": 0.0, "z": 0.05, "roll": 0.0, "pitch": 0.0, "yaw": -0.3}}
        """#)
        #expect(frame.headPose == .euler(x: 0, y: 0, z: 0.05, roll: 0, pitch: 0, yaw: -0.3))
        let transform = try #require(frame.headPose?.transform)
        #expect(abs(transform.translation.z - 0.05) < 1e-12)
    }

    /// Every component defaults to 0 in the daemon's schema, so a partial pose is valid.
    @Test("missing euler components default to zero")
    func partialEulerPose() throws {
        let frame = try decode(#"{"head_pose": {"yaw": 1.0}}"#)
        #expect(frame.headPose == .euler(x: 0, y: 0, z: 0, roll: 0, pitch: 0, yaw: 1.0))
    }

    @Test("an empty frame decodes to all-nil")
    func emptyFrame() throws {
        let frame = try decode("{}")
        #expect(frame.headPose == nil)
        #expect(frame.headJoints == nil)
        #expect(frame.bodyYaw == nil)
    }

    @Test("a null head pose is not an error")
    func nullHeadPose() throws {
        #expect(try decode(#"{"head_pose": null}"#).headPose == nil)
    }

    /// The daemon ships independently of this app.
    @Test("unknown fields never break decoding")
    func unknownFields() throws {
        let frame = try decode(#"{"body_yaw": 0.5, "some_future_daemon_field": {"a": 1}}"#)
        #expect(frame.bodyYaw == 0.5)
    }

    @Test("passive joints arrive as 21 values from a Placo daemon")
    func passiveJoints() throws {
        let values: [String] = (0 ..< 21).map { String(Double($0) / 100) }
        let json = "{\"passive_joints\": [\(values.joined(separator: ","))]}"
        #expect(try decode(json).passiveJoints?.count == 21)
    }
}
