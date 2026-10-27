import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// `motors/set_mode` answers 409 from daemon 1.13.0 for a mode the robot cannot
/// enter: gravity compensation without Placo (pollen-robotics/reachy_mini#1454,
/// `HTTPException(status_code=409, detail=str(e))`). Everywhere else a 409 is a
/// busy daemon, and saying so here would hide the real reason.
@Suite("Motor mode refusals")
struct RobotConnectionMotorModeTests {
    private func connection(_ stub: StubURLProtocol.Stub) throws -> RobotConnection {
        try RobotConnection(
            address: RobotAddress(host: "10.42.0.1"),
            session: StubURLProtocol.makeSession(["/api/motors/set_mode/gravity_compensation": stub])
        )
    }

    @Test("a mode the robot cannot enter keeps the daemon's sentence")
    func keepsTheReason() async throws {
        let detail = "Gravity compensation requires the Placo kinematics engine"
        let connection = try connection(.init(statusCode: 409, json: #"{"detail":"\#(detail)"}"#))

        await #expect(throws: ReachyKitError.daemonRefused(statusCode: 409, detail: detail)) {
            try await connection.setMotorMode(.gravityCompensation)
        }
    }

    @Test("a 409 with nothing to say is still a busy daemon")
    func bareConflictIsBusy() async throws {
        let connection = try connection(.init(statusCode: 409))

        await #expect(throws: ReachyKitError.daemonBusy) {
            try await connection.setMotorMode(.gravityCompensation)
        }
    }
}
