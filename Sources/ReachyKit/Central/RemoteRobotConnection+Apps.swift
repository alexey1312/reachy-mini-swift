import Foundation

/// The app that is running, over the relay.
extension RemoteRobotConnection: RobotAppsClient {
    // MARK: The running app

    // Daemon 1.10.0 put the apps API behind JSON-RPC on this channel and routes by
    // namespace: it answers `apps.*` itself and relays everything else to the app.
    // Only the three verbs about the app *already running* are here — browsing,
    // installing and removing stayed on HTTP, which is what `offersAppStore` says.

    /// No catalogue over this channel, so no store to show.
    public nonisolated var offersAppStore: Bool {
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
        let info: RobotApp?
        let error: String?

        /// Nil for `idle`, which is the daemon saying there is no app rather than
        /// describing one — the same shape `GET /api/apps/current-app-status`
        /// answers with a literal `null`.
        var appStatus: RobotAppStatus? {
            guard state != "idle", let info else { return nil }
            return RobotAppStatus(app: info, state: .init(wire: state), error: error)
        }
    }
}
