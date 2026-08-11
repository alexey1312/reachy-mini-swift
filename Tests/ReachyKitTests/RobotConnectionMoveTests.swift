import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// `POST /api/move/goto`, which is the only "return to base" this app has.
@Suite("Moves over HTTP", .timeLimit(.minutes(1)))
struct RobotConnectionMoveTests {
    private func makeConnection(_ session: URLSession) throws -> RobotConnection {
        try RobotConnection(address: RobotAddress(host: "10.42.0.1"), session: session)
    }

    /// The daemon's own zero, and the reason it is not `[0, 0]`:
    /// `reachy_mini.INIT_ANTENNAS_JOINT_POSITIONS` is `[-0.1745, 0.1745]`, carrying
    /// the comment "to reduce shaking at vertical", and it is what the daemon sends
    /// when it parks the robot itself. Two definitions of base would put a stopped
    /// dance and a stopped app in visibly different poses.
    @Test("the neutral pose is the daemon's own zero")
    func neutralAntennasMatchTheDaemon() {
        #expect(RobotConnection.zeroAntennas == [-0.1745, 0.1745])
    }

    /// The constant and the call are asserted separately on purpose: changing one
    /// without the other is the mistake, and only the wire form catches it.
    ///
    /// Every axis is named explicitly because an omitted `GotoModelRequest` field
    /// means "leave that one where it is", which for a return to base is the one
    /// thing it must not mean.
    @Test("goto sends every axis, with the daemon's antenna pair")
    func gotoNeutralSendsTheWholeZeroPose() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/move/goto": .init(statusCode: 200, json: #"{"uuid": "move-1"}"#),
        ])

        let uuid = try await makeConnection(session).gotoNeutral(duration: 1)

        #expect(uuid == "move-1")
        let body = try #require(StubURLProtocol.bodies(for: session).first)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["antennas"] as? [Double] == [-0.1745, 0.1745])
        #expect(sent["body_yaw"] as? Double == 0)
        let head = try #require(sent["head_pose"] as? [String: Any])
        #expect(head.count == 6)
        #expect(["x", "y", "z", "roll", "pitch", "yaw"].allSatisfy { head[$0] as? Double == 0 })
    }
}
