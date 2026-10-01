import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// A relayed robot from 1.10.0 on, as the store meets it: a catalogue, an install
/// that answers once, a start and a status — and nothing else. The three HTTP-only
/// reads are implemented so a test can prove they are never made.
private final class RelayAppsClient: RobotAPIClient, RobotAppsClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var installs: [String] = []
    private(set) var starts: [String] = []
    private(set) var httpOnlyReads = 0
    var outcome: AppJobMonitor.Outcome = .succeeded
    var running: RobotAppStatus?

    var offersAppStore: Bool {
        false
    }

    var installsFromCatalogue: Bool {
        true
    }

    func handshake() async throws -> RobotConnection.Handshake {
        try await .init(
            identity: .init(hardwareID: "hw-relay", name: "kitchen", daemonVersion: "1.11.0"),
            status: daemonStatus()
        )
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        .preview(state: .running, wirelessVersion: false, version: "1.11.0")
    }

    func wakeUp() async throws -> String {
        ""
    }

    func gotoSleep() async throws -> String {
        ""
    }

    func availableApps() async throws -> [RobotApp] {
        [.preview(name: "reachy_mini_radio"), .preview(name: "face-tracking")]
    }

    func installFromCatalogue(named name: String) async throws -> AppJobMonitor.Outcome {
        lock.withLock { installs.append(name) }
        return outcome
    }

    func currentAppStatus() async throws -> RobotAppStatus? {
        lock.withLock { running }
    }

    func startApp(named name: String) async throws -> RobotAppStatus {
        let status = RobotAppStatus(
            app: RobotApp(Components.Schemas.AppInfo(name: name, sourceKind: .installed)),
            state: .starting
        )
        lock.withLock {
            starts.append(name)
            running = status
        }
        return status
    }

    func appLockStatus() async throws -> RobotAppLockStatus {
        lock.withLock { httpOnlyReads += 1 }
        throw URLError(.unsupportedURL)
    }

    func startupApp() async throws -> String? {
        lock.withLock { httpOnlyReads += 1 }
        throw URLError(.unsupportedURL)
    }

    func appUpdates(force _: Bool) async throws -> AppUpdatesSummary {
        lock.withLock { httpOnlyReads += 1 }
        throw URLError(.unsupportedURL)
    }
}

@MainActor
@Suite("App store over the relay", .timeLimit(.minutes(1)))
struct AppStoreRelayTests {
    private func relayed(_ client: RelayAppsClient) async -> RobotSession {
        let session = RobotSession { _ in client }
        #expect(await session.connect(using: client))
        return session
    }

    /// An Installed section holding only this visit's installs would read as
    /// everything the robot has, so there is none — and a choice made on the LAN
    /// survives the visit rather than being overwritten by it.
    @Test("over the relay the store is Discover alone")
    func showsDiscoverOnly() async {
        let session = await relayed(RelayAppsClient())
        let model = AppStoreModel(session: session)
        model.section = .installed

        await model.load(session: session)

        #expect(model.isOverRelay)
        #expect(model.sections == [.discover])
        #expect(model.shownSection == .discover)
        #expect(model.section == .installed)
        #expect(model.visibleApps.map(\.name) == ["reachy_mini_radio", "face-tracking"])
    }

    /// The lock, the startup app and the update check are all HTTP. Asking over the
    /// relay would only collect three refusals.
    @Test("a relayed load asks nothing the relay cannot answer")
    func skipsTheHTTPOnlyReads() async {
        let client = RelayAppsClient()
        let session = await relayed(client)
        let model = AppStoreModel(session: session)

        await model.load(session: session, refresh: true)

        #expect(client.httpOnlyReads == 0)
    }

    /// Nothing lists what is installed, so a confirmed install is the record — and
    /// Start then sends the slug the install used.
    @Test("an install the robot confirmed makes the card startable by its slug")
    func startsWhatItInstalled() async throws {
        let client = RelayAppsClient()
        let session = await relayed(client)
        let model = AppStoreModel(session: session)
        await model.load(session: session)
        let app = try #require(model.catalogue.first)
        #expect(!model.isInstalled(app))

        await model.reloadInstalled(session: session, after: .succeeded(.install(app)))
        await model.start(app, session: session)

        #expect(model.isInstalled(app))
        #expect(client.starts == ["reachy_mini_radio"])
    }

    /// A failed or unconfirmed install is not an installed app; only the robot's
    /// own "installed" is.
    @Test("an install that did not succeed records nothing")
    func recordsOnlySuccess() async throws {
        let session = await relayed(RelayAppsClient())
        let model = AppStoreModel(session: session)
        await model.load(session: session)
        let app = try #require(model.catalogue.first)

        await model.reloadInstalled(session: session, after: .failed(.install(app), "no"))

        #expect(!model.isInstalled(app))
    }

    /// The running app is the one other proof of an installed app over the relay,
    /// and its name is the daemon's entry point — the name to start it by again.
    @Test("the running app stands in for the installed list")
    func countsTheRunningApp() async throws {
        let client = RelayAppsClient()
        client.running = RobotAppStatus(
            app: RobotApp(Components.Schemas.AppInfo(name: "face_tracking", sourceKind: .installed)),
            state: .error
        )
        let session = await relayed(client)
        let model = AppStoreModel(session: session)
        await model.load(session: session)
        let card = try #require(model.catalogue.first { $0.name == "face-tracking" })

        #expect(model.installedTwin(of: card)?.name == "face_tracking")
    }

    @Test("a relayed install answers once, with no job and no log")
    func installsOverTheRelay() async {
        let client = RelayAppsClient()
        let session = await relayed(client)
        let log = JobEventLog()
        let model = AppInstallModel(
            session: session,
            events: { _, _ in
                Issue.record("a relayed install has no job to follow")
                return AsyncStream { $0.finish() }
            },
            notify: { log.record($0) }
        )
        let app = RobotApp.preview(name: "reachy_mini_radio")

        await model.perform(.install(app))

        #expect(!model.streamsLog)
        #expect(model.state == .succeeded(.install(app)))
        #expect(client.installs == ["reachy_mini_radio"])
        #expect(log.startCount == 1)
        #expect(log.results == [.succeeded(detail: nil)])
    }

    /// The robot's own sentence for a refusal: `install_failed` covers "not in the
    /// catalog" and a failed `pip` alike.
    @Test("a refused install shows the robot's sentence")
    func reportsARefusal() async {
        let client = RelayAppsClient()
        client.outcome = .failed("could not install app 'x' (not in the catalog)")
        let model = await AppInstallModel(session: relayed(client), notify: { _ in })
        let app = RobotApp.preview(name: "x")

        await model.perform(.install(app))

        #expect(model.state == .failed(.install(app), "could not install app 'x' (not in the catalog)"))
    }

    /// No installed list to go and check over the relay, so the LAN's sentence would
    /// send the reader nowhere. What is true instead is that asking again is free —
    /// and the notification still says only that nobody answered.
    @Test("an unconfirmed install says it may still be running, and is announced as unanswered")
    func reportsAnUnconfirmedInstall() async {
        let client = RelayAppsClient()
        client.outcome = .timedOut
        let log = JobEventLog()
        let model = await AppInstallModel(session: relayed(client), notify: { log.record($0) })
        let app = RobotApp.preview(name: "reachy_mini_radio")

        await model.perform(.install(app))

        #expect(model.state == .unconfirmed(.install(app)))
        #expect(!model.isBusy)
        #expect(log.results == [.unanswered])
    }
}
