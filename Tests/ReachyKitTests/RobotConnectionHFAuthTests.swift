import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// `/api/hf-auth/*` — the robot's own Hugging Face account, and the relay that
/// account gets it onto. Every shape here comes from `routers/hf_auth.py`.
@Suite("Hugging Face auth over HTTP", .timeLimit(.minutes(1)))
struct RobotConnectionHFAuthTests {
    private func makeSession(_ stubs: [String: StubURLProtocol.Stub]) -> URLSession {
        StubURLProtocol.makeSession(stubs)
    }

    private func makeConnection(_ session: URLSession) throws -> RobotConnection {
        try RobotConnection(address: RobotAddress(host: "10.42.0.1"), session: session)
    }

    @Test("a robot with no token says so")
    func readsLoggedOutStatus() async throws {
        let session = makeSession([
            "/api/hf-auth/status": .init(statusCode: 200, json: #"{"is_logged_in": false, "username": null}"#),
        ])

        let status = try await makeConnection(session).hfAuthStatus()

        #expect(status.isLoggedIn == false)
        #expect(status.username == nil)
    }

    @Test("a linked robot names the account it is linked to")
    func readsLoggedInStatus() async throws {
        let session = makeSession([
            "/api/hf-auth/status": .init(statusCode: 200, json: #"{"is_logged_in": true, "username": "alexey1312"}"#),
        ])

        let status = try await makeConnection(session).hfAuthStatus()

        #expect(status.isLoggedIn)
        #expect(status.username == "alexey1312")
    }

    /// The LAN hop is plain HTTP, so the one thing this client must never do is
    /// put the token where a proxy, a log or a screenshot can pick it up. The
    /// daemon takes the same care on its own side: it sends the token to central
    /// in an `Authorization` header rather than the URL, for exactly this reason.
    @Test("the token is sent in the body and never in the URL")
    func keepsTheTokenOutOfTheURL() async throws {
        let session = makeSession([
            "/api/hf-auth/save-token": .init(
                statusCode: 200,
                json: #"{"status": "success", "username": "alexey1312"}"#
            ),
        ])
        let token = "hf_ThisIsNotARealTokenButItLooksLikeOne"

        let username = try await makeConnection(session).saveHFToken(token)

        #expect(username == "alexey1312")
        let request = try #require(StubURLProtocol.requests(for: session).first)
        let url = try #require(request.url?.absoluteString)
        #expect(request.httpMethod == "POST")
        #expect(url == "http://10.42.0.1:8000/api/hf-auth/save-token")
        #expect(!url.contains(token))
        let body = try #require(StubURLProtocol.bodies(for: session).first)
        #expect(try JSONSerialization.jsonObject(with: body) as? NSDictionary == ["token": token])
    }

    /// The daemon validates the token by calling `whoami` before storing it, and a
    /// token that fails comes back as a 400 — not a 401.
    @Test("a token the Hub rejects is refused with a 400")
    func rejectsAnInvalidToken() async throws {
        let session = makeSession([
            "/api/hf-auth/save-token": .init(statusCode: 400, json: #"{"detail": "Invalid token"}"#),
        ])

        await #expect(throws: ReachyKitError.daemonRejected(statusCode: 400)) {
            try await makeConnection(session).saveHFToken("nope")
        }
    }

    @Test("unlinking clears the robot's token")
    func deletesTheToken() async throws {
        let session = makeSession([
            "/api/hf-auth/token": .init(statusCode: 200, json: #"{"status": "success"}"#),
        ])

        try await makeConnection(session).deleteHFToken()

        #expect(StubURLProtocol.requests(for: session).first?.httpMethod == "DELETE")
    }

    // MARK: Relay

    @Test("a connected relay reports the state and the flag that agree with it")
    func readsConnectedRelay() async throws {
        let session = makeSession([
            "/api/hf-auth/relay-status": .init(
                statusCode: 200,
                json: #"{"state": "connected", "message": "Connected to central", "is_connected": true}"#
            ),
        ])

        let status = try await makeConnection(session).relayStatus()

        #expect(status.state == .connected)
        #expect(status.isConnected)
        #expect(status.message == "Connected to central")
    }

    /// `RelayState` has six values; the router adds a seventh of its own for a
    /// Lite robot and for a build that ships no relay module. Neither is in the
    /// enum the relay itself defines.
    @Test("a Lite robot answers with a state the relay enum does not have")
    func readsUnavailableRelay() async throws {
        let session = makeSession([
            "/api/hf-auth/relay-status": .init(
                statusCode: 200,
                json: #"{"state": "unavailable", "message": "Coming soon to Lite version", "is_connected": false}"#
            ),
        ])

        let status = try await makeConnection(session).relayStatus()

        #expect(status.state == .unavailable)
        #expect(status.isConnected == false)
    }

    @Test("a state from a newer daemon is carried, not thrown")
    func toleratesUnknownRelayState() async throws {
        let session = makeSession([
            "/api/hf-auth/relay-status": .init(
                statusCode: 200,
                json: #"{"state": "handshaking", "is_connected": false}"#
            ),
        ])

        #expect(try await makeConnection(session).relayStatus().state == .unknown("handshaking"))
    }

    /// The daemon's own docstring is explicit about this: on `skipped` nothing was
    /// kicked off, so a caller that then waits for the relay state to change waits
    /// forever.
    @Test("a refresh that was skipped says so instead of pretending to reconnect")
    func reportsSkippedRefresh() async throws {
        let session = makeSession([
            "/api/hf-auth/refresh-relay": .init(
                statusCode: 200,
                json: #"{"status": "skipped", "token_available": true, "reason": "relay_not_running"}"#
            ),
        ])

        let refresh = try await makeConnection(session).refreshRelay()

        #expect(refresh.didStart == false)
        #expect(refresh.tokenAvailable)
        #expect(refresh.reason == "relay_not_running")
    }

    @Test("a refresh that was accepted reports that it started")
    func reportsRequestedRefresh() async throws {
        let session = makeSession([
            "/api/hf-auth/refresh-relay": .init(
                statusCode: 200,
                json: #"{"status": "requested", "token_available": true}"#
            ),
        ])

        #expect(try await makeConnection(session).refreshRelay().didStart)
    }

    // MARK: Central proxy

    /// The daemon proxies central's robot list so the raw token never reaches this
    /// app over the LAN. `available: false` means "unknown", never "no robots".
    @Test("an unlinked robot proxies nothing and says why")
    func reportsUnauthenticatedProxy() async throws {
        let session = makeSession([
            "/api/hf-auth/central-robot-status": .init(
                statusCode: 200,
                json: #"{"available": false, "robots": [], "reason": "not_authenticated"}"#
            ),
        ])

        let proxy = try await makeConnection(session).centralRobotStatus()

        #expect(proxy.isAvailable == false)
        #expect(proxy.reason == .notAuthenticated)
        #expect(proxy.robots.isEmpty)
    }

    /// Every reason means "unknown", so a new one must decode rather than fail the
    /// whole answer — `invalid_configuration` arrived in 1.11.0 unannounced.
    @Test("every reason the proxy gives decodes, including ones this client never saw", arguments: [
        ("not_authenticated", CentralRobotStatusProxy.Reason.notAuthenticated),
        ("token_invalid", .tokenInvalid),
        ("unreachable", .unreachable),
        ("invalid_configuration", .invalidConfiguration),
        ("http_502", .http(502)),
        ("http_oops", .unknown("http_oops")),
        ("central_on_fire", .unknown("central_on_fire")),
    ])
    func decodesEveryReason(raw: String, expected: CentralRobotStatusProxy.Reason) async throws {
        let session = makeSession([
            "/api/hf-auth/central-robot-status": .init(
                statusCode: 200,
                json: #"{"available": false, "robots": [], "reason": "\#(raw)"}"#
            ),
        ])

        let proxy = try await makeConnection(session).centralRobotStatus()

        #expect(proxy.reason == expected)
    }

    @Test("central's robot list comes through with the keys that identify a robot")
    func decodesProxiedRobots() async throws {
        let session = makeSession([
            "/api/hf-auth/central-robot-status": .init(
                statusCode: 200,
                json: #"""
                {"available": true, "robots": [
                  {"peerId": "peer-7", "robotName": "testbot", "busy": true, "activeApp": "Hand Tracker",
                   "meta": {"name": "testbot", "transport": "wifi", "hardware_id": "a1b2c3d4e5f60718"},
                   "last_seen_age_seconds": 3.2}
                ]}
                """#
            ),
        ])

        let robot = try #require(await makeConnection(session).centralRobotStatus().robots.first)

        #expect(robot.hardwareID == "a1b2c3d4e5f60718")
        #expect(robot.transport == .wifi)
        #expect(robot.isBusy)
        #expect(robot.activeApp == "Hand Tracker")
    }

    /// `peerId` changes on every relay reconnect, so it is the last resort. Daemon
    /// 1.9.0 sends no `install_id` at all — the relay lists it as a future field.
    @Test("a robot is identified by the most stable key it actually sent")
    func fallsBackThroughIdentityKeys() async throws {
        let session = makeSession([
            "/api/hf-auth/central-robot-status": .init(
                statusCode: 200,
                json: #"""
                {"available": true, "robots": [
                  {"peerId": "peer-7", "busy": false, "meta": {"name": "a", "transport": "usb"}},
                  {"peerId": "peer-8", "busy": false,
                   "meta": {"name": "b", "transport": "wifi", "hardware_id": "a1b2c3d4e5f60718"}}
                ]}
                """#
            ),
        ])

        let robots = try await makeConnection(session).centralRobotStatus().robots

        #expect(robots.map(\.id) == ["peer-7", "a1b2c3d4e5f60718"])
        #expect(robots.first?.transport == .usb)
    }
}
