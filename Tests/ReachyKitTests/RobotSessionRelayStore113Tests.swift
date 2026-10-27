import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// Which store a relayed session offers from daemon 1.13.0, decided on the version:
/// an older robot answers every 1.13 verb with `-32601` while `apps.install` still
/// works for it. `RobotSessionRelayStoreTests` holds the 1.10–1.12 store.
@MainActor
@Suite("The relay's store, by daemon version", .timeLimit(.minutes(1)))
struct RobotSessionRelayStore113Tests {
    private func session(version: String?, channel: FakeDataChannel = FakeDataChannel()) -> RobotSession {
        RobotSession.preview(
            status: .preview(version: version),
            address: nil,
            link: .remote,
            client: RemoteRobotConnection(
                channel: channel,
                timeout: .seconds(5),
                catalogue: HubAppCatalogue(session: StubURLProtocol.makeSession([:]))
            )
        )
    }

    @Test(
        "the store follows the version",
        arguments: [("1.11.0", false), ("1.12.0", false), ("1.13.0", true), ("1.14.0", true), (nil, false)]
        as [(String?, Bool)]
    )
    func storeFollowsTheVersion(version: String?, hasStore: Bool) {
        let session = session(version: version)

        #expect(session.hasRelayAppStore == hasStore)
        // One way to install at a time: by name before 1.13, as a job from it.
        #expect(session.canInstallFromCatalogue == !hasStore)
        #expect(session.canRestartApp == hasStore)
        #expect(session.canBrowseApps)
        // The daemon's HTTP store — the startup app, the summary — stays the LAN's.
        #expect(!session.canManageApps)
    }

    /// `describedFromInstalled` asks for the list on every dock poll, so an older
    /// robot would collect a `-32601` each time.
    @Test("an older robot is never asked for its installed list")
    func olderRobotIsNotAsked() async {
        let channel = FakeDataChannel()
        let session = session(version: "1.12.0", channel: channel)

        await #expect(throws: ReachyKitError.appsUnavailable) {
            try await session.installedApps()
        }
        #expect(channel.sent.isEmpty)
    }

    @Test("a job is followed over the relay, with no address")
    func followsAJobWithoutAnAddress() async throws {
        let channel = FakeDataChannel()
        let session = session(version: "1.13.0", channel: channel)
        let connection = try #require(session.client as? RemoteRobotConnection)

        async let started = connection.removeApp(named: "app")
        await waitUntil("the call is on the wire") { !channel.sent.isEmpty }
        channel.emit(#"{"jsonrpc":"2.0","id":1,"result":{"job_id":"j1"}}"#)
        _ = try await started

        let events = try session.appJobEvents(jobID: "j1", configuration: .removal)
        channel.emit(
            #"{"jsonrpc": "2.0", "method": "apps.job_progress", "params": {"job_id": "j1", "#
                + #""command": "remove", "status": "done", "line": null, "final": true}}"#
        )

        var outcome: AppJobMonitor.Outcome?
        for await event in events {
            if case let .finished(ended) = event {
                outcome = ended
            }
        }
        #expect(outcome == .succeeded)
    }
}

/// Polls the condition rather than sleeping a fixed time (project rule 7). On the
/// main actor, because the suite is and the condition reads its channel there.
@MainActor
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
