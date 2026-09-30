import Foundation
import ReachyJSON
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// `/api/hf-auth/oauth/device/*`, mounted from daemon 1.10.0. Every shape here is
/// what `routers/hf_auth.py` and `apps/sources/hf_auth.py` answer in the 1.11.0
/// venv — `start_device_code_login` and `get_device_code_session_status`.
@Suite("Robot device-code sign-in", .timeLimit(.minutes(1)))
struct RobotDeviceLoginTests {
    private func connection(_ stubs: [String: StubURLProtocol.Stub]) throws -> RobotConnection {
        try RobotConnection(address: RobotAddress(host: "10.42.0.1"), session: StubURLProtocol.makeSession(stubs))
    }

    @Test("starting one hands back the code, the page and the robot's pace")
    func startsALogin() async throws {
        let login = try await connection([
            "/api/hf-auth/oauth/device/start": .init(statusCode: 200, json: """
            {"status": "pending", "session_id": "9f2c", "user_code": "WDJB-MJHT",
             "verification_uri": "https://huggingface.co/device",
             "verification_uri_complete": "https://huggingface.co/device?user_code=WDJB-MJHT",
             "interval": 5, "expires_in": 900}
            """),
        ]).startDeviceLogin()

        #expect(login.sessionID == "9f2c")
        #expect(login.userCode == "WDJB-MJHT")
        #expect(login.approvalURL.absoluteString == "https://huggingface.co/device?user_code=WDJB-MJHT")
        #expect(login.interval == .seconds(5))
        #expect(login.expiresIn == .seconds(900))
    }

    /// The Hub may leave out the pre-filled page; the plain one still works.
    @Test("without a pre-filled page the plain one is opened")
    func fallsBackToThePlainPage() throws {
        let login = try JSONCodec.daemon.decode(RobotDeviceLogin.self, from: Data("""
        {"session_id": "9f2c", "user_code": "WDJB-MJHT", "verification_uri": "https://huggingface.co/device"}
        """.utf8))

        #expect(login.approvalURL.absoluteString == "https://huggingface.co/device")
        #expect(login.interval == .seconds(5))
    }

    @Test(
        "every status the daemon answers is read, and an unknown one is kept",
        arguments: [
            (#"{"status": "pending"}"#, RobotDeviceLoginStatus.pending),
            (#"{"status": "authorized", "username": "alexey1312"}"#, .authorized(username: "alexey1312")),
            (
                #"{"status": "expired", "message": "Session expired or not found"}"#,
                .expired(message: "Session expired or not found")
            ),
            (#"{"status": "error", "message": "access_denied"}"#, .failed(message: "access_denied")),
            (#"{"status": "cancelled"}"#, .cancelled),
            (#"{"status": "slow_down"}"#, .unknown("slow_down")),
        ]
    )
    func readsEveryStatus(json: String, expected: RobotDeviceLoginStatus) async throws {
        let status = try await connection([
            "/api/hf-auth/oauth/device/status/9f2c": .init(statusCode: 200, json: json),
        ]).deviceLoginStatus(sessionID: "9f2c")

        #expect(status == expected)
    }

    /// The daemon drops a session once it is done with it, and a cancel after that
    /// has already got what it wanted.
    @Test("cancelling a session the daemon already dropped is not a failure")
    func cancelTolerates404() async throws {
        try await connection([
            "/api/hf-auth/oauth/device/session/9f2c": .init(statusCode: 404, json: #"{"detail": "Session not found"}"#),
        ]).cancelDeviceLogin(sessionID: "9f2c")
    }

    @Test("a daemon before 1.10.0 answers 404 to starting one")
    func olderDaemonRefuses() async throws {
        let robot = try connection([
            "/api/hf-auth/oauth/device/start": .init(statusCode: 404, json: #"{"detail": "Not Found"}"#),
        ])

        await #expect(throws: ReachyKitError.self) { _ = try await robot.startDeviceLogin() }
    }

    @Test(
        "a version is known to be at a floor only when it can be read",
        arguments: [
            ("1.12.0", true), ("1.12.0.dev0", true), ("1.12.0rc1", true), ("1.13.2", true),
            ("1.11.0", false), (nil, false), ("garbage", false),
        ] as [(String?, Bool)]
    )
    func knowsAFloorOnlyOnEvidence(reported: String?, expected: Bool) {
        #expect(DaemonCompatibilityPolicy.isKnownAtLeast("1.12.0", reported: reported) == expected)
    }
}
