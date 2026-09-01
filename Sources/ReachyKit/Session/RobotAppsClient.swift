import Foundation

/// The robot's app store: the catalogue, what is installed, and what is running.
///
/// A protocol of its own rather than more methods on `RobotAPIClient`, for the
/// reason `WiFiConfigClient` and `DaemonUpdateClient` are separate: a remote
/// session reaches this surface over a WebRTC data channel and never reaches
/// `/wifi/*` at all, so the capability split is what lets a screen ask whether a
/// thing is possible instead of finding out from an error.
public protocol RobotAppsClient: Sendable {
    /// Whether this transport can browse and change what is installed.
    ///
    /// Conformance is no longer the whole answer. Daemon 1.10.0 put `apps.*` on
    /// the data channel — start, stop, status and install — so a relayed session
    /// can run an app and say which one is running, while the catalogue, the
    /// removals and the update jobs stay HTTP. This separates "can control the
    /// app that is there" from "can change which apps are there".
    var offersAppStore: Bool { get }

    /// Everything the daemon can offer, catalogue and installed together.
    func availableApps() async throws -> [RobotApp]
    func installedApps() async throws -> [RobotApp]

    /// `nil` when nothing is running — the daemon says so with a literal `null`.
    func currentAppStatus() async throws -> RobotAppStatus?
    func startApp(named name: String) async throws -> RobotAppStatus
    func restartCurrentApp() async throws -> RobotAppStatus
    func stopCurrentApp() async throws

    /// All four return a job id at once; the work happens in the background and
    /// its failure never reaches the HTTP status (see `DaemonJob`).
    func installApp(_ app: RobotApp) async throws -> String
    func installPrivateSpace(id spaceID: String) async throws -> String
    func removeApp(named name: String) async throws -> String
    func updateApp(named name: String) async throws -> String
    func appJob(id jobID: String) async throws -> DaemonJob

    /// Cached daemon-side for five minutes unless forced.
    func appUpdates(force: Bool) async throws -> AppUpdatesSummary

    func startupApp() async throws -> String?
    @discardableResult
    func setStartupApp(_ name: String?) async throws -> String?

    func appLockStatus() async throws -> RobotAppLockStatus
}

/// Defaults keep test doubles focused on the behaviour they exercise.
public extension RobotAppsClient {
    /// True unless a transport says otherwise: every daemon serves `/api/apps/*`.
    var offersAppStore: Bool {
        true
    }

    func availableApps() async throws -> [RobotApp] {
        throw URLError(.unsupportedURL)
    }

    func installedApps() async throws -> [RobotApp] {
        throw URLError(.unsupportedURL)
    }

    func currentAppStatus() async throws -> RobotAppStatus? {
        throw URLError(.unsupportedURL)
    }

    func startApp(named _: String) async throws -> RobotAppStatus {
        throw URLError(.unsupportedURL)
    }

    func restartCurrentApp() async throws -> RobotAppStatus {
        throw URLError(.unsupportedURL)
    }

    func stopCurrentApp() async throws {
        throw URLError(.unsupportedURL)
    }

    func installApp(_: RobotApp) async throws -> String {
        throw URLError(.unsupportedURL)
    }

    func installPrivateSpace(id _: String) async throws -> String {
        throw URLError(.unsupportedURL)
    }

    func removeApp(named _: String) async throws -> String {
        throw URLError(.unsupportedURL)
    }

    func updateApp(named _: String) async throws -> String {
        throw URLError(.unsupportedURL)
    }

    func appJob(id _: String) async throws -> DaemonJob {
        throw URLError(.unsupportedURL)
    }

    func appUpdates(force _: Bool) async throws -> AppUpdatesSummary {
        throw URLError(.unsupportedURL)
    }

    func startupApp() async throws -> String? {
        throw URLError(.unsupportedURL)
    }

    @discardableResult
    func setStartupApp(_: String?) async throws -> String? {
        throw URLError(.unsupportedURL)
    }

    func appLockStatus() async throws -> RobotAppLockStatus {
        throw URLError(.unsupportedURL)
    }
}
