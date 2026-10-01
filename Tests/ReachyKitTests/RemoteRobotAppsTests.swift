import Foundation
import ReachyJSON
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// The apps API over the relay, with the replies daemon 1.11.0's `jsonrpc_relay.py`
/// actually sends. JSON-RPC frames carry no `type`, so `FakeDataChannel` cannot
/// script them: each test waits for the call to reach the wire and answers it by id.
@Suite("Apps over the relay", .timeLimit(.minutes(1)))
struct RemoteRobotAppsTests {
    private func connection(
        _ replies: [String: String] = [:],
        timeout: Duration = .seconds(5),
        installTimeout: Duration = .seconds(5),
        catalogue: HubAppCatalogue = HubAppCatalogue(session: StubURLProtocol.makeSession([:]))
    ) -> (RemoteRobotConnection, FakeDataChannel) {
        let fake = FakeDataChannel(replies: replies)
        return (
            RemoteRobotConnection(
                channel: fake,
                timeout: timeout,
                catalogue: catalogue,
                installTimeout: installTimeout
            ),
            fake
        )
    }

    /// `_status_dict` sends `info` as `{name, description, url}` and nothing else —
    /// no `source_kind`, which the daemon's own REST model requires. A running app
    /// read over the relay therefore has to decode without it.
    @Test("a running app is read off the relay's own status shape")
    func readsTheRelayStatus() async throws {
        let (connection, fake) = connection()

        async let status = connection.currentAppStatus()
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"result":{"state":"running","error":null,"#
                + #""info":{"name":"reachy_mini_dance","description":"","url":null}}}"#
        )

        let read = try #require(try await status)
        #expect(read.app.name == "reachy_mini_dance")
        #expect(read.app.isInstalled)
        #expect(read.state == .running)
    }

    /// The same shape answers a start, so a start that worked must not read as one
    /// that failed to decode.
    @Test("a start answers with the app it started")
    func readsTheStartReply() async throws {
        let (connection, fake) = connection()

        async let status = connection.startApp(named: "reachy_mini_dance")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"result":{"state":"starting","error":null,"#
                + #""info":{"name":"reachy_mini_dance","description":"","url":null}}}"#
        )

        let started = try await status
        #expect(started.app.name == "reachy_mini_dance")
        #expect(started.state == .starting)
    }

    @Test("an install names the app the way the daemon looks it up")
    func sendsTheInstall() async throws {
        let (connection, fake) = connection()

        async let outcome = connection.installFromCatalogue(named: "reachy_mini_radio")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        let sent = try JSONSerialization.jsonObject(with: Data(#require(fake.sent.first).utf8)) as? [String: Any]
        #expect(sent?["method"] as? String == "apps.install")
        #expect((sent?["params"] as? [String: Any])?["name"] as? String == "reachy_mini_radio")
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"installed":true}}"#)

        #expect(try await outcome == .succeeded)
    }

    /// `install_failed` covers "not in the catalog" and a failed `pip` alike, and the
    /// daemon's sentence is the only thing that tells them apart.
    @Test("a refused install carries the robot's own sentence")
    func reportsARefusal() async throws {
        let (connection, fake) = connection()

        async let outcome = connection.installFromCatalogue(named: "nowhere")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"#
                + #""message":"could not install app 'nowhere' (not in the catalog)","#
                + #""data":{"reason":"install_failed"}}}"#
        )

        #expect(try await outcome == .failed("could not install app 'nowhere' (not in the catalog)"))
    }

    /// A robot still in `pip` answers the plain protocol perfectly well, which is
    /// exactly what the silent-relay probe looks for. Reporting that would tell the
    /// reader to restart the robot — the one thing that ends the install.
    @Test("an install the robot is still working on is unknown, not a broken relay")
    func silenceIsUnknown() async throws {
        let (connection, _) = connection(
            ["get_version": #"{"version": "1.11.0"}"#],
            installTimeout: .milliseconds(300)
        )

        #expect(try await connection.installFromCatalogue(named: "reachy_mini_radio") == .timedOut)
    }

    /// The reply budget would end a first install ten seconds in. Measured rather
    /// than assumed, because both budgets end in the same `.timedOut` and the wrong
    /// one would pass on outcome alone (project rule 7).
    @Test("an install waits on its own budget, not the reply budget")
    func waitsOnTheInstallBudget() async throws {
        let (connection, fake) = connection(timeout: .milliseconds(100), installTimeout: .seconds(30))

        let clock = ContinuousClock()
        let start = clock.now
        async let outcome = connection.installFromCatalogue(named: "reachy_mini_radio")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"installed":true}}"#)

        #expect(try await outcome == .succeeded)
        #expect(clock.now - start >= .milliseconds(500))
    }

    @Test("the catalogue over the relay is the Hub's")
    func listsTheHub() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/spaces": .init(statusCode: 200, json: #"[{"id":"pollen-robotics/reachy_mini_radio"}]"#),
        ])
        let (connection, _) = connection(catalogue: HubAppCatalogue(session: session))

        let apps = try await connection.availableApps()

        #expect(apps.map(\.name) == ["reachy_mini_radio"])
        #expect(connection.installsFromCatalogue)
        #expect(!connection.offersAppStore)
    }
}

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
