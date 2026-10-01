import Foundation

/// The robot's apps, over the relay.
extension RemoteRobotConnection: RobotAppsClient {
    // Daemon 1.10.0 put the apps API behind JSON-RPC on this channel and routes by
    // namespace: it answers `apps.*` itself and relays everything else to the app.
    // It answers four verbs — `status`, `start`, `stop` and `install` — and that
    // is the whole surface: the installed list, removals, updates and the startup
    // app stay HTTP, which is what `offersAppStore` says.

    /// Not the daemon's store: no installed list, and no jobs to follow.
    public nonisolated var offersAppStore: Bool {
        false
    }

    // MARK: Installing

    public nonisolated var installsFromCatalogue: Bool {
        true
    }

    /// The Hub's catalogue rather than the robot's: the relay has no listing verb,
    /// and this is the list `apps.install` searches — see `HubAppCatalogue`.
    public func availableApps() async throws -> [RobotApp] {
        try await catalogue.apps()
    }

    /// `apps.install {name}`: install-if-missing, from the catalogue, in a task of
    /// its own on the robot so `apps.status` keeps answering meanwhile
    /// (`jsonrpc_relay.py`, `ensure_startup_app_installed`).
    ///
    /// **The name is the catalogue's**, the Space slug, because that is what the
    /// daemon matches: `a.name == name` against the installed list first, then
    /// against `list_all_apps`. Nothing about the install is reported but its end —
    /// `{"installed": true}`, or a refusal with `install_failed` that covers "not in
    /// the catalog" and a failed `pip` alike.
    ///
    /// **A silence is not a failure here, unless the relay itself is dead.** The
    /// install carries on on the robot whether anybody waits or not, and asking
    /// again costs nothing once it has finished, so a robot still in `pip` ends as
    /// `.timedOut`. But `.relaySilent` alone cannot tell that robot from one whose
    /// JSON-RPC relay died after a backend restart (pollen-robotics/reachy_mini#1421):
    /// both leave the plain protocol answering. One `apps.status` on the reply budget
    /// does — the relay runs every frame in a task of its own, so a live one answers
    /// at once while `pip` runs. It is asked twice: **before** the install, so a dead
    /// relay costs ten seconds rather than a sheet held for three minutes, and after a
    /// silence, for a relay that died mid-install. Only a dead relay is thrown, with
    /// the advice to restart that `.relaySilent` carries.
    ///
    /// Three minutes is three of the LAN install's budgets
    /// (`AppJobMonitor.Configuration.install`). A longer wait buys a few more
    /// confirmed installs at the price of a sheet held open, and the price of a
    /// shorter one is only a second tap.
    public func installFromCatalogue(named name: String) async throws -> AppJobMonitor.Outcome {
        try await control.call("apps.status")
        do {
            try await control.call("apps.install", params: ["name": .string(name)], timeout: installTimeout)
            return .succeeded
        } catch let failure as RemoteControlChannel.Failure {
            switch failure {
            case let .rpc(_, message, _), let .robot(message):
                return .failed(message)
            case .closed:
                return .timedOut
            case .timedOut, .relaySilent:
                do {
                    try await control.call("apps.status")
                } catch RemoteControlChannel.Failure.relaySilent {
                    throw RemoteControlChannel.Failure.relaySilent
                } catch {
                    // Nothing answers at all: the robot or the link is gone, which
                    // says nothing about the install either way.
                }
                return .timedOut
            }
        }
    }

    // MARK: The running app

    /// No `apps.restart`. Stop-then-start is not a safe stand-in either: `apps.stop`
    /// answers only once the daemon's whole stop is over, return to zero included,
    /// which can outlast the reply budget — and a start sent on that timeout would
    /// race a slot still taken.
    public nonisolated var offersRestart: Bool {
        false
    }

    public func currentAppStatus() async throws -> RobotAppStatus? {
        let reply = try await control.call("apps.status", expecting: AppStatusReply.self)
        return reply.appStatus
    }

    public func startApp(named name: String) async throws -> RobotAppStatus {
        let reply = try await control.call(
            "apps.start",
            params: ["name": .string(name)],
            expecting: AppStatusReply.self
        )
        // The daemon answers with the status it reached. A start that produced no
        // app at all is a refusal it did not raise, and reporting it as running
        // would put a name on screen over a robot doing nothing.
        guard let status = reply.appStatus else { throw ReachyKitError.appsUnavailable }
        return status
    }

    public func stopCurrentApp() async throws {
        try await control.call("apps.stop")
    }

    /// `{state, info, error}`, where `info` is the app's own entry and absent while
    /// nothing runs.
    private struct AppStatusReply: Decodable {
        let state: String
        let info: Info?
        let error: String?

        /// Nil for `idle`, which is the daemon saying there is no app rather than
        /// describing one — the same shape `GET /api/apps/current-app-status`
        /// answers with a literal `null`.
        var appStatus: RobotAppStatus? {
            guard state != "idle", let info else { return nil }
            return RobotAppStatus(app: info.app, state: .init(wire: state), error: error)
        }

        /// The relay's own cut of the app: `_status_dict` sends `name`,
        /// `description` and `url`, and stops there.
        ///
        /// **Not a `RobotApp`, and that was a bug.** `AppInfo` requires
        /// `source_kind`, which this reply never carries, so decoding the app
        /// straight into one threw `keyNotFound` for every running app — the dock
        /// read nothing over the relay, and a start the robot had obeyed reported a
        /// failure. Every test double built the status itself, which is how it
        /// passed. `installed` is the daemon's own word for it: `AppManager.start_app`
        /// files every running app that way.
        struct Info: Decodable {
            let name: String
            let description: String?
            let url: String?

            var app: RobotApp {
                RobotApp(Components.Schemas.AppInfo(
                    name: name,
                    sourceKind: .installed,
                    description: description,
                    url: url
                ))
            }
        }
    }
}
