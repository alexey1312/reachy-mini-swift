import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// The hardware id is a join key, not a display string: the robot hands out the same
/// value over BLE and advertises it as the mDNS `unit_id`, so recognising a
/// just-provisioned robot on the LAN is a plain `==`. Any reshaping breaks that
/// silently — nothing throws, the match simply never happens.
@Suite("RobotConnection handshake identity")
struct RobotConnectionHandshakeTests {
    private static func status(hardwareID: String?) -> String {
        let field = hardwareID.map { "\"\($0)\"" } ?? "null"
        return """
        {"type": "daemon_status", "robot_name": "reachy_mini", "state": "running",
         "wireless_version": true, "desktop_app_daemon": false,
         "backend_status": null, "version": "1.9.0", "hardware_id": \(field)}
        """
    }

    private func makeConnection(_ stubs: [String: StubURLProtocol.Stub]) throws -> RobotConnection {
        try RobotConnection(address: RobotAddress(host: "10.0.0.9"), session: StubURLProtocol.makeSession(stubs))
    }

    @Test("the hardware id the status reports is carried through verbatim")
    func usesHardwareIDFromStatus() async throws {
        let connection = try makeConnection([
            "/api/daemon/status": .init(statusCode: 200, json: Self.status(hardwareID: "9f86d081884c7d65")),
            "/api/daemon/robot-name": .init(statusCode: 200, json: #"{"name": "testbot"}"#),
        ])

        let handshake = try await connection.handshake()

        #expect(handshake.identity.hardwareID == "9f86d081884c7d65")
    }

    @Test("a daemon that omits the field falls back to the dedicated route, unwrapping its one key")
    func fallsBackToHardwareIDRoute() async throws {
        let connection = try makeConnection([
            "/api/daemon/status": .init(statusCode: 200, json: Self.status(hardwareID: nil)),
            "/api/daemon/hardware-id": .init(statusCode: 200, json: #"{"hardware_id": "9f86d081884c7d65"}"#),
            "/api/daemon/robot-name": .init(statusCode: 200, json: #"{"name": "testbot"}"#),
        ])

        let handshake = try await connection.handshake()

        #expect(handshake.identity.hardwareID == "9f86d081884c7d65")
    }

    /// **Recents rests on this.** `RobotCallController` puts `identity.name` in the
    /// call handle and falls back to the hardware id, and iOS renders that value
    /// verbatim — so a nameless identity turns a call history row into
    /// `b68ff6bbe47f0608`, which names nothing to anybody. It shipped that way once.
    ///
    /// Today the fallback is unreachable: `robot_name` is required in the spec, so
    /// even a daemon that mounts no rename route still names the robot. That is a
    /// property of the *spec*, not of this code, and `mise run update-spec` is what
    /// would take it away. This test is what notices.
    @Test("the handshake always names the robot, rename route or not")
    func alwaysNamesTheRobot() async throws {
        let connection = try makeConnection([
            "/api/daemon/status": .init(statusCode: 200, json: Self.status(hardwareID: "9f86d081884c7d65")),
            "/api/daemon/robot-name": .init(statusCode: 404, json: #"{"detail": "Not Found"}"#),
        ])

        let handshake = try await connection.handshake()

        #expect(handshake.identity.name == "reachy_mini")
        #expect(handshake.supportsRename == false)
    }

    @Test("a daemon with no robot attached hands back no id rather than failing the handshake")
    func toleratesMissingHardwareID() async throws {
        let connection = try makeConnection([
            "/api/daemon/status": .init(statusCode: 200, json: Self.status(hardwareID: nil)),
            "/api/daemon/hardware-id": .init(statusCode: 200, json: #"{"hardware_id": null}"#),
            "/api/daemon/robot-name": .init(statusCode: 200, json: #"{"name": "reachy_mini"}"#),
        ])

        let handshake = try await connection.handshake()

        #expect(handshake.identity.hardwareID == nil)
        #expect(handshake.identity.deduplicationKey == "reachy_mini")
    }

    @Test("a stub keyed with a query wins over the bare path")
    func narrowerQueryKeyWins() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/daemon/status": .init(statusCode: 500),
            "/api/daemon/status?verbose=1": .init(statusCode: 200, json: Self.status(hardwareID: "abc")),
        ])
        let (data, response) = try await session.data(
            from: #require(URL(string: "http://10.0.0.9:8000/api/daemon/status?verbose=1"))
        )

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(bytes: data, encoding: .utf8)?.contains("abc") == true)
    }
}
