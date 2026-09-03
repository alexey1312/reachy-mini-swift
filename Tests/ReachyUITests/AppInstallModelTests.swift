import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

private final class InstallRobotClient: RobotAPIClient, RobotAppsClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var installed: [RobotApp] = []
    private(set) var privateInstalls: [String] = []
    private(set) var removed: [String] = []
    private(set) var updated: [String] = []
    var refusesToStart = false

    private var daemonState: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name":"testbot","state":"running","wireless_version":true,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":{"motor_control_mode":"enabled","error":null}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(identity: .init(hardwareID: "hw", name: "testbot", daemonVersion: "1.9.0"), status: daemonState)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        daemonState
    }

    func wakeUp() async throws -> String {
        "wake"
    }

    func gotoSleep() async throws -> String {
        "sleep"
    }

    func installApp(_ app: RobotApp) async throws -> String {
        if refusesToStart {
            throw ReachyKitError.daemonRejected(statusCode: 400)
        }
        lock.withLock { installed.append(app) }
        return "job-install"
    }

    func installPrivateSpace(id spaceID: String) async throws -> String {
        lock.withLock { privateInstalls.append(spaceID) }
        return "job-private"
    }

    func removeApp(named name: String) async throws -> String {
        lock.withLock { removed.append(name) }
        return "job-remove"
    }

    func updateApp(named name: String) async throws -> String {
        lock.withLock { updated.append(name) }
        return "job-update"
    }

    func installedApps() async throws -> [RobotApp] {
        []
    }

    func currentAppStatus() async throws -> RobotAppStatus? {
        nil
    }

    func startupApp() async throws -> String? {
        nil
    }
}

@MainActor
@Suite("App install model", .timeLimit(.minutes(1)))
struct AppInstallModelTests {
    private static func app(_ name: String, kind: String = "hf_space", extra: String = "{}") throws -> RobotApp {
        try JSONDecoder().decode(RobotApp.self, from: Data(#"""
        {"name": "\#(name)", "source_kind": "\#(kind)", "extra": \#(extra)}
        """#.utf8))
    }

    private func connected(_ client: InstallRobotClient) async -> RobotSession {
        let session = RobotSession { _ in client }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        return session
    }

    private func events(_ events: [AppJobMonitor.Event]) -> AsyncStream<AppJobMonitor.Event> {
        AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    @Test("an install streams its log and ends in success")
    func installsAnApp() async throws {
        let client = InstallRobotClient()
        let session = await connected(client)
        let app = try Self.app("reachy-mini-dance", extra: #"{"id": "pollen-robotics/reachy-mini-dance"}"#)
        let model = AppInstallModel(session: session) { _, _ in
            events([.line("Collecting reachy-mini"), .status(.done), .finished(.succeeded)])
        }

        await model.perform(.install(app))

        #expect(model.state == .succeeded(.install(app)))
        #expect(client.installed.map(\.name) == ["reachy-mini-dance"])
        #expect(model.log.entries.contains { $0.message.contains("Collecting reachy-mini") })
    }

    /// A private Space cannot be installed by posting its `AppInfo` — the daemon
    /// has to fetch it with the token it stores, through its own route.
    @Test("a private Space goes through the route that uses the robot's token")
    func installsAPrivateSpace() async throws {
        let client = InstallRobotClient()
        let session = await connected(client)
        let app = try Self.app(
            "secret",
            extra: #"{"id": "someone/secret", "private": true}"#
        )
        let model = AppInstallModel(session: session) { _, _ in events([.finished(.succeeded)]) }

        await model.perform(.install(app))

        #expect(client.privateInstalls == ["someone/secret"])
        #expect(client.installed.isEmpty)
    }

    /// The job's failure never reaches the HTTP status — it arrives as a terminal
    /// state with the last log line as its reason.
    @Test("a failed job shows the reason the daemon logged")
    func reportsFailure() async throws {
        let session = await connected(InstallRobotClient())
        let app = try Self.app("reachy-mini-dance")
        let model = AppInstallModel(session: session) { _, _ in
            events([.finished(.failed("No matching distribution found"))])
        }

        await model.perform(.install(app))

        #expect(model.state == .failed(.install(app), "No matching distribution found"))
    }

    /// A restart mid-install is neither success nor failure: the job register died
    /// with the daemon, and the only honest thing is to say so and re-read the list.
    @Test("a daemon restart is its own outcome")
    func reportsDaemonRestart() async throws {
        let session = await connected(InstallRobotClient())
        let app = try Self.app("reachy-mini-dance")
        let model = AppInstallModel(session: session) { _, _ in events([.finished(.daemonRestarted)]) }

        await model.perform(.install(app))

        #expect(model.state == .daemonRestarted(.install(app)))
    }

    @Test("a job that never ends is reported as a timeout, not a failure of its own")
    func reportsTimeout() async throws {
        let session = await connected(InstallRobotClient())
        let app = try Self.app("reachy-mini-dance")
        let model = AppInstallModel(session: session) { _, _ in events([.finished(.timedOut)]) }

        await model.perform(.install(app))

        if case let .failed(_, reason) = model.state {
            #expect(reason.localizedCaseInsensitiveContains("too long"))
        } else {
            Issue.record("expected a failure, got \(model.state)")
        }
    }

    /// Upstream's budgets, which are what the robot was tested against: 60 s for an
    /// install, 90 s for a removal.
    @Test("each operation gets its own deadline")
    func usesPerOperationTimeouts() async throws {
        let session = await connected(InstallRobotClient())
        let app = try Self.app("dance_party", kind: "installed")
        let budgets = Budgets()
        let model = AppInstallModel(session: session) { _, configuration in
            budgets.record(configuration.timeout)
            return events([.finished(.succeeded)])
        }

        await model.perform(.install(app))
        await model.perform(.remove(app))

        #expect(budgets.recorded == [.seconds(60), .seconds(90)])
    }

    @Test("a daemon that refuses to start the job says so before any log appears")
    func reportsRefusedStart() async throws {
        let client = InstallRobotClient()
        client.refusesToStart = true
        let session = await connected(client)
        let app = try Self.app("local-thing")
        let model = AppInstallModel(session: session) { _, _ in events([]) }

        await model.perform(.install(app))

        if case .failed = model.state {} else {
            Issue.record("expected a failure, got \(model.state)")
        }
    }

    @Test("removing and updating are keyed by the installed name")
    func removesAndUpdatesByName() async throws {
        let client = InstallRobotClient()
        let session = await connected(client)
        let app = try Self.app("dance_party", kind: "installed")
        let model = AppInstallModel(session: session) { _, _ in events([.finished(.succeeded)]) }

        await model.perform(.remove(app))
        await model.perform(.update(app))

        #expect(client.removed == ["dance_party"])
        #expect(client.updated == ["dance_party"])
    }

    // MARK: - What a long job tells anyone waiting on it

    /// **The assertion that pins the whole design.** The screen collapses a timeout
    /// into a failure, because the sheet is in front of someone who can go and look.
    /// The notification must not: nobody answered, and "failed" would be a verdict
    /// inferred from a timer. Unify the two mappings and this goes red.
    @Test("a timeout reads as a failure on screen and as an unanswered job to anyone away from it")
    func timeoutIsAFailureOnScreenAndSilenceInTheAnnouncement() async throws {
        let log = JobEventLog()
        let session = await connected(InstallRobotClient())
        let app = try Self.app("reachy-mini-dance")
        let model = AppInstallModel(
            session: session,
            events: { _, _ in events([.finished(.timedOut)]) },
            notify: { log.record($0) }
        )

        await model.perform(.install(app))

        guard case .failed = model.state else {
            Issue.record("expected a failure on screen, got \(model.state)")
            return
        }
        #expect(log.results == [.unanswered])
    }

    /// The model announces the outcome faithfully; deciding that a successful removal
    /// is not worth a banner belongs to `JobNotificationPlan`, which is where it is
    /// tested. Splitting it this way is what keeps the policy in one place.
    @Test("each operation announces its own kind, and reports the outcome unedited")
    func announcesEachOperationUnderItsOwnKind() async throws {
        let session = await connected(InstallRobotClient())
        let app = try Self.app("dance_party", kind: "installed")
        let expected: [(AppInstallModel.Operation, JobNotificationPlan.Kind)] = [
            (.install(app), .appInstall), (.update(app), .appUpdate), (.remove(app), .appRemove),
        ]

        for (operation, kind) in expected {
            let log = JobEventLog()
            let model = AppInstallModel(
                session: session,
                events: { _, _ in events([.finished(.succeeded)]) },
                notify: { log.record($0) }
            )
            await model.perform(operation)
            #expect(log.notices.allSatisfy { $0.key.kind == kind }, "\(operation) announced the wrong kind")
            #expect(log.results == [.succeeded(detail: nil)])
        }
    }

    /// The daemon's own name is the key and the title is only display text, so a
    /// rename under a running job cannot change what the announcement is about.
    @Test("the announcement is keyed by the daemon's name and reads with the title")
    func announcementIsKeyedByNameAndReadsWithTitle() async throws {
        let log = JobEventLog()
        let session = await connected(InstallRobotClient())
        let app = try Self.app("dance_party", kind: "installed")
        let model = AppInstallModel(
            session: session,
            events: { _, _ in events([.finished(.succeeded)]) },
            notify: { log.record($0) }
        )

        await model.perform(.install(app))

        #expect(log.notices.allSatisfy { $0.key.subject == "dance_party" })
        #expect(log.notices.allSatisfy { $0.subjectTitle == app.title })
        #expect(log.notices.allSatisfy { $0.robotName == "testbot" })
    }

    /// A stream that simply ends is the absence of an event, and nothing may be
    /// announced on an absence — the rule `RunningAppActivityPlan` states as "never
    /// on silence", reaching this model through its own choke point.
    @Test("a job whose stream ends without an outcome announces no outcome")
    func aStreamThatEndsQuietlyAnnouncesNothing() async throws {
        let log = JobEventLog()
        let session = await connected(InstallRobotClient())
        let model = AppInstallModel(
            session: session,
            events: { _, _ in events([.line("Collecting")]) },
            notify: { log.record($0) }
        )

        try await model.perform(.install(Self.app("reachy-mini-dance")))

        #expect(log.startCount == 1)
        #expect(log.results.isEmpty)
    }

    /// A daemon that refuses the job outright still produces an error that *arrived*,
    /// which is the difference between this and the case above.
    @Test("a daemon that refuses to start the job announces the failure")
    func aRefusedStartIsAnnounced() async throws {
        let log = JobEventLog()
        let client = InstallRobotClient()
        client.refusesToStart = true
        let session = await connected(client)
        let model = AppInstallModel(
            session: session,
            events: { _, _ in events([]) },
            notify: { log.record($0) }
        )

        try await model.perform(.install(Self.app("local-thing")))

        #expect(log.results.count == 1)
        guard case .failed = log.results[0] else {
            Issue.record("expected a failure, got \(log.results)")
            return
        }
    }

    @Test("dismissing clears the outcome so the overlay can go away")
    func dismisses() async throws {
        let session = await connected(InstallRobotClient())
        let model = AppInstallModel(session: session) { _, _ in events([.finished(.succeeded)]) }

        try await model.perform(.install(Self.app("reachy-mini-dance")))
        model.dismiss()

        #expect(model.state == .idle)
        #expect(model.log.entries.isEmpty)
    }
}

private final class Budgets: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []

    var recorded: [Duration] {
        lock.withLock { values }
    }

    func record(_ duration: Duration) {
        lock.withLock { values.append(duration) }
    }
}
