import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// Daemon 1.14.0 on the data channel: the startup app (pollen-robotics/reachy_mini#1476)
/// and `client_hello` (#1532). The replies are `_handle_apps` and `get_version` at the
/// v1.14.0 tag.
@Suite("Daemon 1.14 over the relay", .timeLimit(.minutes(1)))
struct RemoteRobotStartupAppTests {
    private func connection(
        version: String = "1.14.0",
        hello: Bool? = nil
    ) -> (RemoteRobotConnection, FakeDataChannel) {
        let helloField = hello.map { #","client_hello":\#($0)"# } ?? ""
        let fake = FakeDataChannel(replies: [
            "get_version": #"{"version":"\#(version)"\#(helloField)}"#,
            "get_hardware_id": #"{"hardware_id":"hw-1"}"#,
            "get_state": #"{"state":{"motor_mode":"enabled"}}"#,
        ])
        return (RemoteRobotConnection(channel: fake, timeout: .seconds(5)), fake)
    }

    private func objects(_ fake: FakeDataChannel) -> [[String: Any]] {
        fake.sent.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func calls(_ fake: FakeDataChannel) -> [[String: Any]] {
        objects(fake).filter { $0["method"] != nil }
    }

    @Test("the startup app is read, by its null too", arguments: [
        (#""reachy_mini_dance""#, "reachy_mini_dance" as String?),
        ("null", nil),
    ])
    func readsTheStartupApp(wire: String, expected: String?) async throws {
        let (connection, fake) = connection()

        async let startup = connection.startupApp()
        await waitUntil("the call is on the wire") { !calls(fake).isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"name":\#(wire)}}"#)

        #expect(try await startup == expected)
        #expect(calls(fake).first?["method"] as? String == "apps.get_startup")
    }

    /// The daemon refuses a bare `{}` so that nothing clears the setting by accident,
    /// so the key has to be on the wire with a null in it.
    @Test("clearing the startup app sends the key, with a null")
    func clearsTheStartupApp() async throws {
        let (connection, fake) = connection()

        async let startup = connection.setStartupApp(nil)
        await waitUntil("the call is on the wire") { !calls(fake).isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"name":null}}"#)

        #expect(try await startup == nil)
        let params = try #require(calls(fake).first?["params"] as? [String: Any])
        #expect(params.keys.contains("name"))
        #expect(params["name"] is NSNull)
    }

    @Test("setting the startup app names it")
    func setsTheStartupApp() async throws {
        let (connection, fake) = connection()

        async let startup = connection.setStartupApp("reachy_mini_dance")
        await waitUntil("the call is on the wire") { !calls(fake).isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"name":"reachy_mini_dance"}}"#)

        #expect(try await startup == "reachy_mini_dance")
        let params = try #require(calls(fake).first?["params"] as? [String: Any])
        #expect(params["name"] as? String == "reachy_mini_dance")
    }

    /// `apps.get_startup` before 1.14.0 is `-32601`, and before 1.10.0 nothing answers a
    /// JSON-RPC frame at all, so a version not known to carry it never sends one.
    @Test("an older robot is never asked for its startup app", arguments: ["1.9.0", "1.13.0"])
    func olderRobotIsNotAsked(version: String) async {
        let (connection, fake) = connection(version: version)

        await #expect(throws: ReachyKitError.appsUnavailable) {
            _ = try await connection.startupApp()
        }
        #expect(calls(fake).isEmpty)
    }

    @Test("the session offers it from 1.14.0", arguments: [
        ("1.13.0", false), ("1.14.0", true), (nil, false),
    ] as [(String?, Bool)])
    @MainActor
    func sessionGate(version: String?, offers: Bool) {
        let session = RobotSession.preview(
            status: .preview(version: version),
            address: nil,
            link: .remote,
            client: RemoteRobotConnection(channel: FakeDataChannel(), timeout: .seconds(5))
        )

        #expect(session.hasRelayStartupApp == offers)
    }

    @Test("the client is named once, in the header's own words, when the robot asks")
    func saysHello() async throws {
        let (connection, fake) = connection(hello: true)

        _ = try await connection.daemonStatus()
        _ = try await connection.daemonStatus()

        let hellos = objects(fake).filter { $0["type"] as? String == "client_hello" }
        #expect(hellos.count == 1)
        #expect(hellos.first?["client"] as? String == ReachyClientHeader.value)
        #expect(hellos.first?.keys.contains("app") == false)
    }

    /// False is the owner's telemetry switch, and an absent field is a daemon before
    /// 1.14.0, which would answer the command with an error nothing waits for.
    @Test("nothing is sent when the robot does not ask", arguments: [false as Bool?, nil])
    func staysQuiet(hello: Bool?) async throws {
        let (connection, fake) = connection(hello: hello)

        _ = try await connection.daemonStatus()

        #expect(!objects(fake).contains { $0["type"] as? String == "client_hello" })
    }
}

/// Polls the condition rather than sleeping a fixed time (project rule 7).
private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}
