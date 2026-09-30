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
    /// **The plan only errs towards keeping the backend once it knows there is
    /// something to keep.** So a failed read of the startup app plans the teardown —
    /// what powering off always was, and right for the robot with none, which is
    /// most of them; every supported daemon has the route (it arrived in 1.9.0, the
    /// floor), so the failure is a robot not answering, and the teardown sent next
    /// is likely to be refused the same way. A client that cannot ask at all — the
    /// relay, whose vocabulary has no startup app and no `daemon/stop` either — lands
    /// here too and keeps the refusal it always gave. A failed read of the status,
    /// with a startup app already known, plans the sleep: a sleep sent at a stopped
    /// backend is refused out loud and changes nothing, while a teardown sent at a
    /// running one silently switches the antenna off. `RobotPowerOffModel.refresh`
    /// holds the same line from the other side — a known answer is kept through a
    /// read that fails.
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
