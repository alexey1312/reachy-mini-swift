import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// A daemon with a small store: one official Space, one community Space, and one
/// of them installed under a different name.
///
/// Internal rather than private: `AppStoreCacheTests` needs the same robot.
final class StoreRobotClient: RobotAPIClient, RobotAppsClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var started: [String] = []
    private(set) var stopCalls = 0
    private(set) var catalogueCalls = 0
    private(set) var startupWrites: [String?] = []
    var runningApp: RobotAppStatus?
    var lockStatus = RobotAppLockStatus(state: .free)
    var startup: String?
    var failsCatalogue = false
    var catalogueResponse = StoreRobotClient.catalogue
    /// Settable because starting an app now depends on both: a stopped backend is
    /// refused, and disabled motors are woken first.
    var state: Components.Schemas.DaemonState = .running
    var motorMode: Components.Schemas.MotorControlMode = .enabled
    private(set) var motorWrites: [Components.Schemas.MotorControlMode] = []

    private var daemonState: Components.Schemas.DaemonStatus {
        let backend = state == .running
            ? #"{"motor_control_mode":"\#(motorMode.rawValue)","error":null}"#
            : "null"
        let json = """
        {"robot_name":"testbot","state":"\(state.rawValue)","wireless_version":true,
         "desktop_app_daemon":false,"simulation_enabled":true,"mockup_sim_enabled":false,
         "backend_status":\(backend)}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        lock.withLock {
            motorWrites.append(mode)
            motorMode = mode
        }
    }

    func runningMoveUUIDs() async throws -> Set<String> {
        []
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

    func availableApps() async throws -> [RobotApp] {
        lock.withLock { catalogueCalls += 1 }
        if failsCatalogue {
            throw ReachyKitError.daemonRejected(statusCode: 503)
        }
        return catalogueResponse
    }

    func installedApps() async throws -> [RobotApp] {
        catalogueResponse.filter(\.isInstalled)
    }

    func currentAppStatus() async throws -> RobotAppStatus? {
        runningApp
    }

    func appLockStatus() async throws -> RobotAppLockStatus {
        lockStatus
    }

    func startupApp() async throws -> String? {
        startup
    }

    @discardableResult
    func setStartupApp(_ name: String?) async throws -> String? {
        lock.withLock {
            startupWrites.append(name)
            startup = name
        }
        return name
    }

    func startApp(named name: String) async throws -> RobotAppStatus {
        lock.withLock { started.append(name) }
        let status = RobotAppStatus(app: Self.app(named: name, kind: "installed"), state: .running)
        runningApp = status
        return status
    }

    func stopCurrentApp() async throws {
        lock.withLock { stopCalls += 1 }
        runningApp = nil
    }

    func appUpdates(force _: Bool) async throws -> AppUpdatesSummary {
        // swiftlint:disable:next force_try
        try! AppUpdatesSummary(JSONDecoder().decode(
            Components.Schemas.AppUpdatesResponse.self,
            from: Data(#"""
            {"apps_with_updates": [{"app_name": "dance_party", "space_id": "pollen-robotics/reachy-mini-dance",
              "installed_sha": "a", "latest_sha": "b", "update_available": true}],
             "apps_checked": 2, "apps_skipped": 0}
            """#.utf8)
        ))
    }

    static func app(named name: String, kind: String, extra: String = "{}") -> RobotApp {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(RobotApp.self, from: Data(#"""
        {"name": "\#(name)", "source_kind": "\#(kind)", "extra": \#(extra)}
        """#.utf8))
    }

    /// What `list-available` serves: the catalogue and the installed list in one
    /// answer, curated entries first (`list_all_available_apps`).
    static let catalogue: [RobotApp] = [
        app(
            named: "reachy-mini-dance",
            kind: "hf_space",
            extra: #"""
            {"id": "pollen-robotics/reachy-mini-dance", "author": "pollen-robotics", "likes": 42,
             "cardData": {"title": "Dance Party", "emoji": "\#u{1F483}"}}
            """#
        ),
        app(
            named: "chess",
            kind: "hf_space",
            extra: #"""
            {"id": "someone/chess", "author": "someone", "likes": 3, "cardData": {"title": "Chess Coach"}}
            """#
        ),
        // The same app as the first card, installed under its Python entry point
        // name, with no metadata to tie the two together.
        app(named: "reachy_mini_dance", kind: "installed"),
    ]
}

@MainActor
@Suite("App store model", .timeLimit(.minutes(1)))
struct AppStoreModelTests {
    @Test("a new store starts in the content-loading state")
    func initialContentLoading() {
        let model = AppStoreModel(session: RobotSession())

        #expect(model.isContentLoading)
        #expect(!model.loading)
    }

    private func connected(_ client: StoreRobotClient) async -> RobotSession {
        let session = RobotSession { _ in client }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        return session
    }

    private func loaded(_ client: StoreRobotClient = StoreRobotClient()) async -> (AppStoreModel, RobotSession) {
        let session = await connected(client)
        let model = AppStoreModel(session: session)
        await model.load(session: session)
        return (model, session)
    }

    @Test("one answer from the daemon becomes two sections")
    func splitsTheOneList() async {
        let (model, _) = await loaded()

        model.section = .installed
        #expect(model.visibleApps.map(\.name) == ["reachy_mini_dance"])

        model.section = .discover
        #expect(model.visibleApps.map(\.name) == ["reachy-mini-dance", "chess"])
    }

    /// The daemon puts curated entries ahead of the rest; re-sorting would throw
    /// away the only editorial signal the store has.
    @Test("the daemon's own ordering is kept")
    func keepsDaemonOrdering() async {
        let (model, _) = await loaded()
        model.section = .discover

        #expect(model.visibleApps.first?.title == "Dance Party")
    }

    @Test("a successful empty catalogue becomes an empty state, not a loader")
    func emptyCatalogueIsAResult() async {
        let client = StoreRobotClient()
        client.catalogueResponse = []
        let (model, _) = await loaded(client)

        #expect(model.visibleApps.isEmpty)
        #expect(!model.isContentLoading)
    }

    @Test("search matches the title, the author and the space id")
    func searches() async {
        let (model, _) = await loaded()
        model.section = .discover

        model.searchText = "dance"
        #expect(model.visibleApps.map(\.title) == ["Dance Party"])

        model.searchText = "SOMEONE"
        #expect(model.visibleApps.map(\.title) == ["Chess Coach"])

        model.searchText = "pollen-robotics/reachy-mini-dance"
        #expect(model.visibleApps.map(\.title) == ["Dance Party"])

        model.searchText = "nothing here"
        #expect(model.visibleApps.isEmpty)
    }

    /// The card in Discover has to find the installed row that start/stop/remove
    /// are keyed by, across the name change.
    @Test("a catalogue card finds the installed app it is")
    func findsTheInstalledTwin() async throws {
        let (model, _) = await loaded()
        model.section = .discover
        let card = try #require(model.visibleApps.first)

        #expect(model.installedTwin(of: card)?.name == "reachy_mini_dance")
        #expect(model.isInstalled(card))
        #expect(model.isInstalled(model.visibleApps[1]) == false)
    }

    @Test("an update on the installed app badges its catalogue card too")
    func badgesUpdates() async {
        let (model, _) = await loaded()
        model.section = .discover

        #expect(model.hasUpdate(model.visibleApps[0]))
        #expect(model.hasUpdate(model.visibleApps[1]) == false)
    }

    @Test("the running app is recognised through the same name change")
    func recognisesTheRunningApp() async {
        let client = StoreRobotClient()
        client.runningApp = RobotAppStatus(
            app: StoreRobotClient.app(named: "reachy_mini_dance", kind: "installed"),
            state: .running
        )
        let (model, _) = await loaded(client)
        model.section = .discover

        #expect(model.runningApp?.state == .running)
        #expect(model.isRunning(model.visibleApps[0]))
        #expect(model.isRunning(model.visibleApps[1]) == false)
    }

    /// A robot driven from the Hugging Face relay is not broken and not free — the
    /// screen has to say which, and by whom.
    @Test("a remote session is reported as one, with its holder")
    func reportsRemoteSession() async {
        let client = StoreRobotClient()
        client.lockStatus = RobotAppLockStatus(state: .remoteSession, holderName: "alexey1312")
        let (model, _) = await loaded(client)

        #expect(model.isHeldRemotely)
        #expect(model.lockHolder == "alexey1312")
    }

    @Test("a local app holding the robot is not a remote session")
    func distinguishesLocalHolder() async {
        let client = StoreRobotClient()
        client.lockStatus = RobotAppLockStatus(state: .localApp, holderName: "dance_party")
        let (model, _) = await loaded(client)

        #expect(model.isHeldRemotely == false)
        #expect(model.lockHolder == "dance_party")
    }

    @Test("the startup app is flagged on whichever card is that app")
    func flagsTheStartupApp() async {
        let client = StoreRobotClient()
        client.startup = "reachy_mini_dance"
        let (model, _) = await loaded(client)
        model.section = .discover

        #expect(model.isStartupApp(model.visibleApps[0]))
        #expect(model.isStartupApp(model.visibleApps[1]) == false)
    }

    @Test("choosing a startup app sends the installed name, not the Space slug")
    func setsStartupAppByInstalledName() async {
        let client = StoreRobotClient()
        let (model, session) = await loaded(client)
        model.section = .discover
        let card = model.visibleApps[0]

        await model.setStartupApp(card, session: session)

        #expect(client.startupWrites == ["reachy_mini_dance"])
    }

    @Test("starting an app from its catalogue card starts the installed one")
    func startsByInstalledName() async {
        let client = StoreRobotClient()
        let (model, session) = await loaded(client)
        model.section = .discover

        await model.start(model.visibleApps[0], session: session)

        #expect(client.started == ["reachy_mini_dance"])
    }

    /// The daemon starts an app at a sleeping robot without a word — `start-app`
    /// is not behind the `get_backend` dependency — and every motion the app then
    /// sends is swallowed by disabled motors.
    @Test("starting an app wakes a sleeping robot first")
    func startingWakesASleepingRobot() async {
        let client = StoreRobotClient()
        client.motorMode = .disabled
        let (model, session) = await loaded(client)
        model.section = .discover

        await model.start(model.visibleApps[0], session: session)

        #expect(client.motorWrites == [.enabled])
        #expect(client.started == ["reachy_mini_dance"])
        #expect(model.lastError == nil)
    }

    /// The way back from a stopped backend is a 90 s job, which is a decision
    /// rather than something to discover inside a tap. The screen offers it as a
    /// button; this refuses and says why — **on the store's own model**, because
    /// `robotError` holds connection and power and is not a fallback for anything.
    ///
    /// The robot is parked first and the backend torn down after, which is what
    /// makes the refusal reachable: a cached status saying "awake" is believed and
    /// skips the read (`RobotAppLauncher.assumeAwake`), so only a robot the session
    /// already knows is not awake asks the daemon again.
    @Test("a stopped backend refuses the start and reports it on the store")
    func refusesToStartWithTheBackendDown() async {
        let client = StoreRobotClient()
        client.motorMode = .disabled
        let (model, session) = await loaded(client)
        client.state = .stopped
        model.section = .discover

        await model.start(model.visibleApps[0], session: session)

        #expect(client.started.isEmpty)
        #expect(model.lastError?.isEmpty == false)
        #expect(session.robotError == nil)
    }

    @Test("a daemon that will not answer leaves the reason on the model")
    func reportsFailure() async {
        let client = StoreRobotClient()
        client.failsCatalogue = true
        let (model, _) = await loaded(client)

        #expect(model.visibleApps.isEmpty)
        #expect(model.lastError?.isEmpty == false)
        #expect(model.loading == false)
        #expect(!model.isContentLoading)
    }

    @Test("a failed refresh keeps an existing catalogue on screen")
    func failedRefreshKeepsCatalogue() async {
        let client = StoreRobotClient()
        let (model, session) = await loaded(client)
        model.section = .discover
        let titles = model.visibleApps.map(\.title)
        client.failsCatalogue = true

        await model.load(session: session, refresh: true)

        #expect(model.visibleApps.map(\.title) == titles)
        #expect(model.lastError?.isEmpty == false)
        #expect(!model.isContentLoading)
    }

    @Test("refreshing a loaded catalogue does not replace it with the content loader")
    func loadedRefreshIsNonBlocking() {
        let model = AppStoreModel.preview(catalogue: RobotApp.previewCatalogue, loading: true)

        #expect(model.loading)
        #expect(!model.visibleApps.isEmpty)
        #expect(!model.isContentLoading)
    }
}
