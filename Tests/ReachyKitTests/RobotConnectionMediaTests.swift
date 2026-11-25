import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// `POST /api/media/acquire`, which a camera session sends when somebody asks for the
/// picture.
@Suite("Media acquire over HTTP", .timeLimit(.minutes(1)))
struct RobotConnectionMediaTests {
    private func makeConnection(_ session: URLSession) throws -> RobotConnection {
        try RobotConnection(address: RobotAddress(host: "10.42.0.1"), session: session)
    }

    @Test("an acquire the robot answers is no failure")
    func acquireSucceeds() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/acquire": .init(statusCode: 200, json: #"{"status": "ok"}"#),
        ])

        try await makeConnection(session).acquireMedia()
    }

    /// The body is daemon 1.15.0's own (`routers/media.py`, pollen-robotics/reachy_mini#1567).
    @Test("a pipeline that did not start is named as such")
    func pipelineThatDidNotStart() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/acquire": .init(statusCode: 500, json: #"{"detail": "Media pipeline failed to start"}"#),
        ])

        await #expect(throws: ReachyKitError.mediaDidNotStart) {
            try await makeConnection(session).acquireMedia()
        }
    }

    @Test("another refusal keeps its status")
    func otherRefusal() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/acquire": .init(statusCode: 503, json: #"{"detail": "Backend not running"}"#),
        ])

        await #expect(throws: ReachyKitError.backendNotRunning) {
            try await makeConnection(session).acquireMedia()
        }
    }
}
