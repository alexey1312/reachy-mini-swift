import ReachyKit

/// What a row says about an app — installed, running, updatable, on wake-up, held —
/// all read off the store's lists and none of it writing anything.
///
/// A file of its own for `AppStoreFilters.swift`'s reason: `AppStoreModel.swift` sits
/// at SwiftLint's file limit, and `--strict` turns that warning into a build failure.
extension AppStoreModel {
    /// The installed row a catalogue card stands for. Everything the daemon does to
    /// an app — start, stop, remove, update, auto-start — is keyed by *that* name,
    /// which the Space author chose independently of the slug.
    func installedTwin(of app: RobotApp) -> RobotApp? {
        if app.isInstalled {
            return app
        }
        return installed.first { app.matches(installed: $0) } ?? relayTwin(of: app)
    }

    func isInstalled(_ app: RobotApp) -> Bool {
        installedTwin(of: app) != nil
    }

    func hasUpdate(_ app: RobotApp) -> Bool {
        guard let updates, let twin = installedTwin(of: app) else { return false }
        return updates.hasUpdate(for: twin) || updates.hasUpdate(for: app)
    }

    func isRunning(_ app: RobotApp) -> Bool {
        guard let runningApp, let twin = installedTwin(of: app) else { return false }
        return runningApp.app.name == twin.name
    }

    func isStartupApp(_ app: RobotApp) -> Bool {
        guard let startupApp, let twin = installedTwin(of: app) else { return false }
        return startupApp == twin.name
    }

    /// Someone is driving this robot from outside the LAN. Worth distinguishing
    /// from a local app: the user cannot simply stop it from here.
    var isHeldRemotely: Bool {
        lock?.state == .remoteSession
    }

    var lockHolder: String? {
        lock?.holderName
    }
}
