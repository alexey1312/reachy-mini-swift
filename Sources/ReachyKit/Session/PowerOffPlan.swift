import Foundation

/// Which of two things Power off should be, decided afresh each time it is asked
/// for.
///
/// **An app set to start on wake-up needs the backend.** Since 1.9 the daemon
/// starts that app when somebody touches an antenna, and the watcher that notices
/// the touch reads the antennas through the backend: it polls `daemon.backend`
/// and idles while that is `None` (`daemon/app/startup_app.py:237`), which is
/// exactly what `Daemon.stop` leaves behind (`daemon/daemon.py:604`) — lines as of
/// 1.11.0, and `main` is unchanged. So `daemon/stop` leaves the robot deaf to the
/// touch until something starts the backend again. A sleeping robot still hears it:
/// `wake_or_start_startup_app_if_idle` enables the motors, wakes the robot and
/// then starts the app.
///
/// Pollen's desktop app settled it the same way (reachy-mini-desktop-app#291):
/// with a startup app set, its power button puts the robot to sleep and leaves
/// the daemon up. The Robot screen offers the teardown as a second choice that
/// says what it costs; a door with nobody to ask gets the sleep.
public enum PowerOffPlan: Equatable, Sendable {
    /// Nothing needs the backend, so it goes: `daemon/stop?goto_sleep=true`.
    case stopBackend
    /// Sleep, and leave the backend listening for a touch that starts this app.
    case sleep(keepingStartupApp: String)

    /// A backend that is already down has no watcher left to keep, and a sleep
    /// would be refused with a 503 — so that robot is planned the old way.
    public init(startupApp: String?, isBackendRunning: Bool) {
        if let startupApp, !startupApp.isEmpty, isBackendRunning {
            self = .sleep(keepingStartupApp: startupApp)
        } else {
            self = .stopBackend
        }
    }

    /// Reads both facts from the robot itself, the startup app first.
    ///
    /// **A failed read of the startup app plans the teardown**, which is what a
    /// daemon older than 1.9 answers with a 404 and what powering off always was.
    /// A failed read of the status plans the sleep instead, because the two
    /// mistakes are not the same size: a sleep sent at a stopped backend is refused
    /// out loud and changes nothing, while a teardown sent at a running one
    /// silently switches the antenna off.
    ///
    /// The status is only read once a startup app is known, so a robot without
    /// one costs a single request, and the shape of every call sequence that
    /// predates this stays the same.
    public static func read(apps: any RobotAppsClient, daemon: any RobotAPIClient) async -> PowerOffPlan {
        guard let startupApp = try? await apps.startupApp() else { return .stopBackend }
        let status = try? await daemon.daemonStatus()
        return PowerOffPlan(startupApp: startupApp, isBackendRunning: status?.isBackendRunning ?? true)
    }

    /// The same read through one client that speaks both halves. One that cannot
    /// list apps cannot have a startup app to keep either.
    public static func read(from client: any RobotAPIClient) async -> PowerOffPlan {
        guard let apps = client as? any RobotAppsClient else { return .stopBackend }
        return await read(apps: apps, daemon: client)
    }
}
