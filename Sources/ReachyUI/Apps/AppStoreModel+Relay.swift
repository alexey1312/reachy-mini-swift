import ReachyKit

/// The store over the relay: the Hub's catalogue, read by this device, with
/// `apps.install` behind it — and, before daemon 1.13.0, no list of what the robot
/// has installed.
extension AppStoreModel {
    /// Whether this store is the relay's. Screens word their failures by it: over
    /// the relay it is this device that could not reach Hugging Face, not the robot.
    var isOverRelay: Bool {
        session.canInstallFromCatalogue || session.hasRelayAppStore
    }

    /// Whether the robot can say what it has installed, and so be asked to update
    /// and remove it: the LAN always, the relay from daemon 1.13.0.
    var listsInstalled: Bool {
        !isOverRelay || session.hasRelayAppStore
    }

    /// The sections this transport can fill. Over an older relay that is Discover
    /// alone: nothing there lists what is installed, and an Installed section
    /// holding only this visit's installs would read as everything the robot has.
    var sections: [Section] {
        listsInstalled ? Section.allCases : [.discover]
    }

    /// `section` as far as the transport allows — the picker's choice survives a
    /// relay visit rather than being overwritten by it.
    var shownSection: Section {
        sections.contains(section) ? section : .discover
    }

    /// The same question over the relay, where nothing lists what is installed and
    /// two things stand in for the list.
    ///
    /// - **The app the robot says is running.** Its name is the daemon's own entry
    ///   point, so it is the name to start it by again. The relay's status carries
    ///   no Space id, so the match is by name — exact when any card has that exact
    ///   name, and only otherwise by the daemon's normalised spelling, so that
    ///   `face_tracking` running never lights up a `face-tracking` card beside a
    ///   `face_tracking` one.
    /// - **An install this visit made.** The catalogue card itself answers, which
    ///   makes the slug the name Start sends. That is the daemon's own assumption —
    ///   `ensure_startup_app_installed` checks the installed list by the very name
    ///   it installs by — and an author who named the entry point differently gets
    ///   the daemon's refusal on Start, which the screen shows, rather than a
    ///   guess.
    ///
    /// Neither is the full list, and neither is offered as one: `sections` keeps
    /// Installed off the relay.
    func relayTwin(of app: RobotApp) -> RobotApp? {
        guard isOverRelay, !listsInstalled else { return nil }
        if let running = runningApp?.app {
            let named = catalogue.contains { $0.name == running.name }
            if named ? app.name == running.name : app.matches(installed: running) {
                return running
            }
        }
        return installedOverRelay.contains(app.id) ? app : nil
    }
}

/// Daemon 1.13.0's relay store: the installed list is read like the LAN's, and an
/// update is checked one app at a time, because the relay has no summary.
extension AppStoreModel {
    /// `apps.check_update` for the app on screen: one Hugging Face call on the
    /// robot, so it is asked here rather than for the whole list.
    func checkUpdateOverRelay(_ app: RobotApp) async {
        guard session.hasRelayAppStore, let twin = installedTwin(of: app) else { return }
        if let check = try? await session.appUpdateCheck(named: twin.name) {
            relayUpdates[twin.name] = check.updateAvailable
        }
    }
}
