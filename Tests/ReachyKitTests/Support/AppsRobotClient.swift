import Foundation
@testable import ReachyKit
import Testing

/// A daemon that can serve apps. `RobotAPIClient` is what `connect` needs;
/// `RobotAppsClient` is the capability the session gates the store on.
///
/// Shared rather than private to one suite: what a session writes into the App
/// Group is checked from more than one angle, and each angle needs a robot that
/// answers `/api/apps/*`.
final class AppsRobotClient: RobotAPIClient, RobotAppsClient, CacheMaintenanceClient, MovePlaybackClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private(set) var catalogueCalls = 0
    private(set) var installedCalls = 0
    private(set) var resetAppsCalls = 0
    private(set) var moveCalls: [String] = []
    /// Recorded-move libraries this robot serves, keyed by dataset. Here rather
    /// than in a second client because the catalogue cache holds both indexes and
    /// a test about it needs a robot that answers both.
    var moveFixtures: [String: [String]] = [:]
    private(set) var removed: [String] = []
    private(set) var running: RobotAppStatus?
    var failsCatalogue = false
    var returnsEmptyInstalled = false
    /// Replaces the one-app installed list, for the tests that need an entry
    /// carrying the metadata the daemon leaves off a running-app status.
    var installedFixtures: [RobotApp]?
    /// What the handshake reports. Settable so a test can prove a cached catalogue
    /// belongs to one robot and is invisible to another (project rule 4).
    var hardwareID = "hw"

    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name":"testbot","state":"running","wireless_version":true,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":{"motor_control_mode":"enabled","error":null}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        let hardwareID = lock.withLock { self.hardwareID }
        return .init(
            identity: .init(hardwareID: hardwareID, name: "testbot", daemonVersion: "1.9.0"),
            status: status
        )
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        status
    }

    func wakeUp() async throws -> String {
        "wake"
    }

    func gotoSleep() async throws -> String {
        "sleep"
    }

    func listMoves(dataset: String) async throws -> [String] {
        lock.withLock { moveCalls.append(dataset) }
        return lock.withLock { moveFixtures[dataset] ?? [] }
    }

    func availableApps() async throws -> [RobotApp] {
        lock.withLock { catalogueCalls += 1 }
        if failsCatalogue {
            throw ReachyKitError.daemonRejected(statusCode: 503)
        }
        return [
            Self.app(name: "reachy-mini-dance", kind: "hf_space"),
            Self.app(name: "dance_party", kind: "installed"),
        ]
    }

    func installedApps() async throws -> [RobotApp] {
        lock.withLock { installedCalls += 1 }
        if returnsEmptyInstalled {
            return []
        }
        return installedFixtures ?? [Self.app(name: "dance_party", kind: "installed")]
    }

    func removeApp(named name: String) async throws -> String {
        lock.withLock { removed.append(name) }
        return "job-1"
    }

    func currentAppStatus() async throws -> RobotAppStatus? {
        lock.withLock { running }
    }

    func startApp(named name: String) async throws -> RobotAppStatus {
        let status = Self.status(name: name)
        lock.withLock { running = status }
        return status
    }

    func stopCurrentApp() async throws {
        lock.withLock { running = nil }
    }

    func setRunning(_ status: RobotAppStatus?) {
        lock.withLock { running = status }
    }

    /// `/cache/reset-apps` deletes the environment every installed app lives in,
    /// so a session holding either app cache is holding fiction afterwards. Here
    /// so `RobotSessionAppsTests` can prove it drops them.
    func resetApps() async throws {
        lock.withLock { resetAppsCalls += 1 }
    }

    func clearHuggingFaceCache() async throws {}

    static func status(name: String, state: String = "running", error: String? = nil) -> RobotAppStatus {
        let reason = error.map { "\"\($0)\"" } ?? "null"
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(RobotAppStatus.self, from: Data(#"""
        {"info": {"name": "\#(name)", "source_kind": "installed", "extra": {}},
         "state": "\#(state)", "error": \#(reason)}
        """#.utf8))
    }

    static func app(name: String, kind: String) -> RobotApp {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(RobotApp.self, from: Data(#"""
        {"name": "\#(name)", "source_kind": "\#(kind)", "extra": {}}
        """#.utf8))
    }

    /// An installed entry shaped like the ones `list-available/installed` really
    /// returns — the daemon's own `custom_app_url` beside the Hub's card. The
    /// running-app status carries none of this, which is what makes the two
    /// halves worth joining.
    static func describedApp(name: String, spaceID: String, port: Int) -> RobotApp {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(RobotApp.self, from: Data(#"""
        {"name": "\#(name)", "source_kind": "installed",
         "extra": {"id": "\#(spaceID)", "author": "pollen-robotics",
                   "custom_app_url": "http://0.0.0.0:\#(port)/",
                   "cardData": {"title": "Reachy Mini Conversation App", "emoji": "🎤",
                                "short_description": "Talk with Reachy Mini!"}}}
        """#.utf8))
    }
}

/// What a session leaves behind for the widget. One table per test: `--parallel`
/// runs suites concurrently, and a single shared `UserDefaults` would have them
/// overwrite each other's readings.
struct AppSessionStores {
    let snapshots: RobotSnapshotStore
    let apps: RobotAppsCacheStore

    init(defaults: UserDefaults) {
        snapshots = RobotSnapshotStore(defaults: defaults)
        apps = RobotAppsCacheStore(defaults: defaults)
    }

    static func make(_ label: String) throws -> AppSessionStores {
        try AppSessionStores(defaults: #require(UserDefaults(suiteName: "\(label).\(UUID().uuidString)")))
    }
}

/// `catalogues` defaults to nothing, the way `RobotSession` itself does: a suite
/// that has not asked for a disk cache must not acquire one.
@MainActor
func connectedAppSession(
    _ client: any RobotAPIClient,
    stores: AppSessionStores,
    catalogues: RobotCatalogueCache? = nil
) async throws -> RobotSession {
    let session = RobotSession(
        snapshots: stores.snapshots,
        appsCache: stores.apps,
        catalogues: catalogues
    ) { _ in client }
    #expect(await session.connect(to: .init(host: "127.0.0.1")))
    return session
}
