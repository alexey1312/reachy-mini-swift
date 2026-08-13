import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// The two daemon-side behaviours that give a robot presence: audio-reactive head
/// wobbling, and visual face tracking.
///
/// Neither can be read back — `media/status` describes the media server, and a face
/// target's `detected: false` cannot tell "tracking off" from "nobody there". So the
/// reply to the write is the only signal there is, and only tracking's is honest.
@Suite("Presence over HTTP", .timeLimit(.minutes(1)))
struct RobotConnectionPresenceTests {
    private func makeConnection(_ session: URLSession) throws -> RobotConnection {
        try RobotConnection(address: RobotAddress(host: "10.42.0.1"), session: session)
    }

    @Test("enabling tracking reports what the robot actually did")
    func trackingReportsItsOwnAnswer() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/tracking/enable": .init(statusCode: 200, json: #"{"status":"ok","enabled":true}"#),
        ])

        #expect(try await makeConnection(session).setFaceTracking(true))
    }

    /// A robot with no camera — or a daemon without the `vision` extra — answers
    /// `unavailable`, and `enable_head_tracking` returns False. That is a refusal
    /// wearing a 200, and reporting it as success is what would put a switch on
    /// screen over a robot that is not tracking anything.
    @Test("a robot with no camera reports the refusal rather than a success")
    func trackingReportsUnavailable() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/tracking/enable": .init(statusCode: 200, json: #"{"status":"unavailable","enabled":false}"#),
        ])

        #expect(try await makeConnection(session).setFaceTracking(true) == false)
    }

    @Test("disabling tracking takes the other route")
    func disablesTracking() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/tracking/disable": .init(statusCode: 200, json: #"{"status":"ok","enabled":false}"#),
        ])

        #expect(try await makeConnection(session).setFaceTracking(false) == false)
    }

    /// `wobbling/enable` returns `{"status": "ok"}` from *outside* the
    /// `if backend._media_server is not None` that does the work, so a 200 does not
    /// mean it took. Nothing here can fix that — the point is not to claim otherwise.
    @Test("wobbling is sent, and its answer proves only that the route exists")
    func sendsWobbling() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/wobbling/enable": .init(statusCode: 200, json: #"{"status":"ok"}"#),
        ])

        try await makeConnection(session).setWobbling(true)

        #expect(StubURLProtocol.requests(for: session).first?.url?.path == "/api/media/wobbling/enable")
    }

    /// Both routes are behind `get_backend`, so a torn-down backend answers 503 —
    /// which is a robot that cannot do this right now, not a robot that will not.
    @Test("a stopped backend surfaces as the daemon's own refusal")
    func reportsStoppedBackend() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/wobbling/enable": .init(statusCode: 503, json: #"{"detail":"Backend not running"}"#),
        ])

        await #expect(throws: (any Error).self) {
            try await makeConnection(session).setWobbling(true)
        }
    }
}
