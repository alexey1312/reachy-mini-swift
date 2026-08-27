import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// A daemon with a small store: one official Space, one community Space, and one
/// of them installed under a different name.
///
/// Internal rather than private: `AppStoreCacheTests` needs the same robot.
final class StoreRobotClient: RobotAPIClient, RobotAppsClient, HFAuthClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var started: [String] = []
    private(set) var stopCalls = 0
    private(set) var catalogueCalls = 0
    private(set) var startupWrites: [String?] = []
    var runningApp: RobotAppStatus?
    var lockStatus = RobotAppLockStatus(state: .free)
    var startup: String?
    /// Logged in by default: every other test in this file loads the store, and the
    /// store now reads this on the way in.
    var hfStatus = HFAuthStatus(isLoggedIn: true, username: "tester")
    private(set) var savedTokens: [String] = []
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

    func hfAuthStatus() async throws -> HFAuthStatus {
        hfStatus
    }

    /// `refreshRelay` is left throwing on purpose — the daemon saves the token
    /// before it touches the relay, so a store that waited for the relay would gate
    /// a robot it had just linked.
    @discardableResult
    func saveHFToken(_ token: String) async throws -> String? {
        savedTokens.append(token)
        hfStatus = HFAuthStatus(isLoggedIn: true, username: "tester")
        return hfStatus.username
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
