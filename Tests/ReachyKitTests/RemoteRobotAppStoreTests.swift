import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// Daemon 1.13.0's store over the relay. Every reply here is a byte copy of what
/// the daemon's own `JsonRpcRelay` answered when driven with a real `AppManager`
/// from a `reachy-mini==1.13.0` venv, except `list_installed` with rows in it,
/// which is `_installed_dict` at v1.13.0 — the simulator had nothing installed.
@Suite("The robot's store over the relay, daemon 1.13", .timeLimit(.minutes(1)))
struct RemoteRobotAppStoreTests {
    private func connection() -> (RemoteRobotConnection, FakeDataChannel) {
        let fake = FakeDataChannel()
        return (RemoteRobotConnection(
            channel: fake,
            timeout: .seconds(5),
            catalogue: HubAppCatalogue(session: StubURLProtocol.makeSession([:]))
        ), fake)
    }

    private func sentCall(_ fake: FakeDataChannel, at index: Int = 0) throws -> [String: Any] {
        let text = try #require(fake.sent.dropFirst(index).first)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test("the installed list joins a catalogue card by its Space id")
    func readsTheInstalledList() async throws {
        let (connection, fake) = connection()

        async let installed = connection.installedApps()
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"result":{"apps":["#
                + #"{"name":"reachy_mini_dance","description":"Ten choreographies.","url":null,"#
                + #""space_id":"pollen-robotics/reachy-mini-dance","title":"Dance Party","emoji":"💃","#
                + #""private":false,"custom_app_url":"http://0.0.0.0:7860/","later_field":1},"#
                + #"{"name":"local_app","description":"","url":null,"space_id":null,"title":null,"#
                + #""emoji":null,"private":false,"custom_app_url":null}]}}"#
        )

        let apps = try await installed
        #expect(try sentCall(fake)["method"] as? String == "apps.list_installed")
        #expect(apps.count == 2)
        let dance = try #require(apps.first)
        #expect(dance.isInstalled)
        #expect(dance.title == "Dance Party")
        #expect(dance.spaceID == "pollen-robotics/reachy-mini-dance")
        #expect(dance.isOfficial)
        #expect(dance.customAppPort == 7860)
        #expect(RobotApp.previewCatalogue[0].matches(installed: dance))
        #expect(apps[1].spaceID == nil)
        #expect(apps[1].isInstalled)
    }

    /// By Space id, which is what the daemon looks the app up by: a slug could
    /// resolve to somebody's fork.
    @Test("an install names the card's Space id and answers the job")
    func installsBySpaceID() async throws {
        let (connection, fake) = connection()
        let app = RobotApp.previewCatalogue[0]

        async let job = connection.installApp(app)
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"job_id":"j1","name":"reachy_mini_dance"}}"#)

        #expect(try await job == "j1")
        let call = try sentCall(fake)
        #expect(call["method"] as? String == "apps.install_space")
        #expect((call["params"] as? [String: Any])?["space_id"] as? String == app.spaceID)
    }

    @Test("a card with no Space id is not sent")
    func refusesACardWithoutASpace() async throws {
        let (connection, fake) = connection()
        let card = RobotApp(Components.Schemas.AppInfo(name: "local", sourceKind: .installed))

        await #expect(throws: ReachyKitError.appsUnavailable) {
            try await connection.installApp(card)
        }
        #expect(fake.sent.isEmpty)
    }

    @Test("a removal names the installed app and answers the job")
    func removes() async throws {
        let (connection, fake) = connection()

        async let job = connection.removeApp(named: "reachy_mini_dance")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"job_id":"a83337ed-40ce-4d73-8592-a71f8de07414"}}"#)

        #expect(try await job == "a83337ed-40ce-4d73-8592-a71f8de07414")
        let call = try sentCall(fake)
        #expect(call["method"] as? String == "apps.remove")
        #expect((call["params"] as? [String: Any])?["name"] as? String == "reachy_mini_dance")
    }

    @Test("a job's status decodes as the LAN's")
    func readsAJob() async throws {
        let (connection, fake) = connection()

        async let job = connection.appJob(id: "0e0094b0")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc": "2.0", "id": 1, "result": {"job_id": "0e0094b0", "command": "remove", "#
                + #""status": "failed", "logs": ["Job 'remove' failed with error: Cannot uninstall app "#
                + #"'nope': it is not installed"]}}"#
        )

        let read = try await job
        #expect(read.status == .failed)
        #expect(read.logs.count == 1)
    }

    /// The job register lives in the daemon's memory. `AppJobMonitor` reads a 404 as
    /// the daemon having restarted, so the relay's answer for it is passed on as one.
    @Test("an unknown job reads as the LAN's 404")
    func unknownJobIsA404() async throws {
        let (connection, fake) = connection()

        async let job = connection.appJob(id: "nope")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "Job ID not found", "#
                + #""data": {"reason": "unknown_job"}}}"#
        )

        do {
            _ = try await job
            Issue.record("an unknown job must throw")
        } catch let error as ReachyKitError {
            #expect(error.statusCode == 404)
        }
    }

    @Test("an update check decodes")
    func readsAnUpdateCheck() async throws {
        let (connection, fake) = connection()

        async let check = connection.appUpdateCheck(named: "nope")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc": "2.0", "id": 1, "result": {"installed": false, "version": null, "#
                + #""update_available": false, "checkable": false, "updating": false, "error": null}}"#
        )

        #expect(try await check == AppUpdateCheck(
            installed: false,
            updateAvailable: false,
            checkable: false
        ))
    }

    @Test("a restart answers with the app it started")
    func restarts() async throws {
        let (connection, fake) = connection()

        async let status = connection.restartCurrentApp()
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"result":{"state":"starting","error":null,"#
                + #""info":{"name":"reachy_mini_dance","description":"","url":null}}}"#
        )

        #expect(try await status.app.name == "reachy_mini_dance")
        #expect(try sentCall(fake)["method"] as? String == "apps.restart")
    }
}

/// The job log, kept from line 0 by `RelayAppJobLedger`.
@Suite("Relay job progress", .timeLimit(.minutes(1)))
struct RelayAppJobLedgerTests {
    private func progress(
        _ job: String,
        _ line: String?,
        status: String = "in_progress",
        final: Bool = false
    ) -> String {
        let text = line.map { #""\#($0)""# } ?? "null"
        return #"{"jsonrpc": "2.0", "method": "apps.job_progress", "params": {"job_id": "\#(job)", "#
            + #""command": "remove", "status": "\#(status)", "line": \#(text), "final": \#(final)}}"#
    }

    private func collect(_ stream: AsyncStream<JobLogEvent>) async -> [JobLogEvent] {
        var events: [JobLogEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    /// Nothing orders the progress against the reply that names the job, so lines
    /// that arrive first must still be there when the job is followed.
    @Test("lines that arrive before the job id are kept, in order")
    func keepsLinesBeforeTheReply() async throws {
        let fake = FakeDataChannel()
        let connection = RemoteRobotConnection(channel: fake, timeout: .seconds(5))

        async let job = connection.removeApp(named: "app")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(progress("j1", "first"))
        fake.emit(progress("j1", "second"))
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"job_id":"j1"}}"#)
        #expect(try await job == "j1")
        fake.emit(progress("j1", nil, status: "done", final: true))

        let events = await collect(connection.jobLog(id: "j1"))

        #expect(events == [.line("first"), .line("second"), .status(.done), .closed])
    }

    @Test("another client's job does not reach this one")
    func filtersByJob() async throws {
        let fake = FakeDataChannel()
        let connection = RemoteRobotConnection(channel: fake, timeout: .seconds(5))

        async let job = connection.removeApp(named: "app")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"job_id":"j1"}}"#)
        _ = try await job
        fake.emit(progress("other", "not mine"))
        fake.emit(progress("j1", "mine"))
        fake.emit(progress("j1", nil, status: "failed", final: true))

        let events = await collect(connection.jobLog(id: "j1"))

        #expect(events == [.line("mine"), .status(.failed), .closed])
    }

    /// An update that joined a job already running has missed its first lines, so
    /// its lines here have no index to share with the poll's. Only the end is passed on.
    @Test("a joined update passes on its end, not its lines")
    func joinedUpdateCarriesTheEndAlone() async throws {
        let fake = FakeDataChannel()
        let connection = RemoteRobotConnection(channel: fake, timeout: .seconds(5))

        async let job = connection.updateApp(named: "app")
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"started":false,"job_id":"j1"}}"#)
        _ = try await job
        fake.emit(progress("j1", "line twelve"))
        fake.emit(progress("j1", nil, status: "done", final: true))

        let events = await collect(connection.jobLog(id: "j1"))

        #expect(events == [.status(.done), .closed])
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
