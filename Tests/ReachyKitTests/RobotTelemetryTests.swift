import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// The robot's telemetry choice (daemon 1.13.0). Reply shapes are the daemon's own:
/// `routers/telemetry.py` for HTTP, `_telemetry_status` in `backend/abstract.py`
/// for the data channel, both at v1.13.0, and the HTTP ones were also read off a
/// `sim-daemon` 1.13.0 with `curl`.
@Suite("Robot telemetry", .timeLimit(.minutes(1)))
struct RobotTelemetryTests {
    private func connection(_ stubs: [String: StubURLProtocol.Stub]) throws -> (RobotConnection, URLSession) {
        let session = StubURLProtocol.makeSession(stubs)
        return try (RobotConnection(address: RobotAddress(host: "10.42.0.1"), session: session), session)
    }

    @Test("the LAN reads the choice and the variable that overrides it")
    func readsOverTheLAN() async throws {
        let (connection, _) = try connection([
            "/api/telemetry": .init(statusCode: 200, json: #"{"enabled":true,"disabled_by_env":true}"#),
        ])

        let telemetry = try await connection.telemetry()

        #expect(telemetry == RobotTelemetry(isEnabled: true, isDisabledByEnvironment: true))
        #expect(telemetry?.isSharing == false)
    }

    /// 1.12.0 answers 404, measured against `sim-daemon`. That is a robot without
    /// the setting, not a failure.
    @Test("a daemon without the route has no setting")
    func olderDaemonHasNone() async throws {
        let (connection, _) = try connection([
            "/api/telemetry": .init(statusCode: 404, json: #"{"detail":"Not Found"}"#),
        ])

        #expect(try await connection.telemetry() == nil)
    }

    @Test("the LAN write sends the field the daemon reads, and answers what it stored")
    func writesOverTheLAN() async throws {
        let (connection, session) = try connection([
            "/api/telemetry": .init(statusCode: 200, json: #"{"enabled":false,"disabled_by_env":false}"#),
        ])

        let stored = try await connection.setTelemetry(enabled: false)

        #expect(stored == RobotTelemetry(isEnabled: false, isDisabledByEnvironment: false))
        let request = try #require(StubURLProtocol.requests(for: session).first)
        #expect(request.httpMethod == "PUT")
        let body = try JSONSerialization.jsonObject(with: #require(StubURLProtocol.bodies(for: session).first))
        #expect((body as? [String: Any])?["enabled"] as? Bool == false)
    }

    /// The daemon answers 500 when it cannot write its config file, and says so.
    @Test("a write the daemon could not save carries its sentence")
    func carriesTheSaveFailure() async throws {
        let (connection, _) = try connection([
            "/api/telemetry": .init(statusCode: 500, json: #"{"detail":"Could not save setting: read-only"}"#),
        ])

        let refusal = ReachyKitError.daemonRefused(statusCode: 500, detail: "Could not save setting: read-only")
        await #expect(throws: refusal) {
            try await connection.setTelemetry(enabled: true)
        }
    }

    @Test("the relay reads the echoed reply")
    func readsOverTheRelay() async throws {
        let channel = FakeDataChannel(replies: [
            "get_telemetry": #"{"command":"get_telemetry","status":"ok","enabled":false,"disabled_by_env":false}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        #expect(try await connection.telemetry() == RobotTelemetry(isEnabled: false, isDisabledByEnvironment: false))
    }

    @Test("the relay write names the field the daemon reads")
    func writesOverTheRelay() async throws {
        let channel = FakeDataChannel(replies: [
            "set_telemetry": #"{"command":"set_telemetry","status":"ok","enabled":true,"disabled_by_env":false}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        #expect(try await connection.setTelemetry(enabled: true).isEnabled)
        let sent = try JSONSerialization.jsonObject(with: Data(#require(channel.sent.first).utf8)) as? [String: Any]
        #expect(sent?["type"] as? String == "set_telemetry")
        #expect(sent?["enabled"] as? Bool == true)
    }

    /// `status: "error"` is a write the robot could not save, answered with the
    /// choice it still holds. Reporting that as the new state would show a switch
    /// in a place the robot never went.
    @Test("a relay write the robot could not save throws")
    func relayWriteFailureThrows() async throws {
        let channel = FakeDataChannel(replies: [
            "set_telemetry": #"{"command":"set_telemetry","status":"error","enabled":true,"disabled_by_env":false}"#,
        ])
        let connection = RemoteRobotConnection(channel: channel, timeout: .seconds(5))

        await #expect(throws: RemoteControlChannel.Failure.self) {
            try await connection.setTelemetry(enabled: false)
        }
    }

    /// An older relayed daemon answers an unknown command with an `error` that names
    /// no command, which matches no waiter: asking it costs the whole reply budget.
    @MainActor
    @Test(
        "the relay is asked only from 1.13.0",
        arguments: [("1.12.0", false), ("1.13.0", true), ("1.13.1", true), (nil, false)] as [(String?, Bool)]
    )
    func relayNeedsAKnownVersion(version: String?, offered: Bool) {
        let session = RobotSession.preview(
            status: .preview(version: version),
            address: nil,
            link: .remote,
            client: PreviewRemoteRobotClient()
        )

        #expect(session.canShareTelemetry == offered)
    }

    /// The LAN reads its 404, so it needs no version.
    @MainActor
    @Test("the LAN is asked whatever the version")
    func lanAsksAnyVersion() {
        #expect(RobotSession.preview(status: .preview(version: "1.12.0")).canShareTelemetry)
        #expect(RobotSession.preview(status: .preview(version: nil)).canShareTelemetry)
    }

    @MainActor
    @Test("the in-app simulator has no setting")
    func simulatorHasNone() {
        #expect(!RobotSession.preview(address: nil, link: .simulated).canShareTelemetry)
    }
}
