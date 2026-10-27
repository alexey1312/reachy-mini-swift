import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// Daemon 1.13.0 counts which kinds of client talk to it from `X-Reachy-Client`, and
/// drops a value that does not match its pattern without a word. So the pattern is
/// the daemon's own, copied from `src/reachy_mini/daemon/telemetry.py` at v1.13.0.
@Suite("X-Reachy-Client")
struct ReachyClientHeaderTests {
    private static let daemonPattern = #"^([a-z_]{1,16})/([0-9A-Za-z.+-]{1,32})(?: \(([a-z]{1,16})\))?$"#

    private func parses(_ value: String) -> Bool {
        value.range(of: Self.daemonPattern, options: .regularExpression) != nil
    }

    @Test("the value parses as the daemon reads it")
    func parses() {
        #expect(parses(ReachyClientHeader.value))
        #expect(ReachyClientHeader.value.hasPrefix("hey_reachy/"))
    }

    /// A test process has no bundle version, and the header must still parse.
    @Test(
        "a missing or odd version still parses",
        arguments: [nil, "", "0.7.3 (beta)", String(repeating: "9", count: 40)]
    )
    func versionAlwaysParses(version: String?) {
        let value = ReachyClientHeader.make(version: version, system: "ios")

        #expect(parses(value), "\(value)")
    }

    @Test("a version is kept as it is when it is already valid")
    func keepsAValidVersion() {
        #expect(ReachyClientHeader.make(version: "0.7.3", system: "macos") == "hey_reachy/0.7.3 (macos)")
        #expect(ReachyClientHeader.make(version: nil, system: "ios") == "hey_reachy/unknown (ios)")
    }

    private static let status = """
    {"robot_name": "reachy_mini", "state": "running", "wireless_version": true,
     "desktop_app_daemon": false, "version": "1.13.0", "backend_status": null}
    """

    @Test("a generated route carries it")
    func generatedRouteCarriesIt() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/daemon/status": .init(statusCode: 200, json: Self.status),
        ])
        let connection = try RobotConnection(address: RobotAddress(host: "10.42.0.1"), session: session)

        _ = try await connection.daemonStatus()

        let request = try #require(StubURLProtocol.requests(for: session).first)
        #expect(request.value(forHTTPHeaderField: "X-Reachy-Client") == ReachyClientHeader.value)
    }

    @Test("a hand-written route carries it")
    func handWrittenRouteCarriesIt() async throws {
        let session = StubURLProtocol.makeSession([
            "/cache/clear-hf": .init(statusCode: 200, json: #"{"status":"success","message":"ok"}"#),
        ])
        let connection = try RobotConnection(address: RobotAddress(host: "10.42.0.1"), session: session)

        try await connection.clearHuggingFaceCache()

        let request = try #require(StubURLProtocol.requests(for: session).first)
        #expect(request.value(forHTTPHeaderField: "X-Reachy-Client") == ReachyClientHeader.value)
    }

    /// Central is not the daemon, and reads nothing from it.
    @Test("central never receives it")
    func centralNeverReceivesIt() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/robot-status": .init(statusCode: 200, json: #"{"robots":[]}"#),
        ])
        let relay = try CentralRelayClient(
            configuration: .init(baseURL: #require(URL(string: "https://central.example")), clientName: "Test"),
            session: session,
            token: { "hf_token" }
        )

        _ = try? await relay.robots()

        let request = try #require(StubURLProtocol.requests(for: session).first)
        #expect(request.value(forHTTPHeaderField: "X-Reachy-Client") == nil)
    }
}
