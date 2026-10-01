import ReachyKit

/// The store over the relay: the Hub's catalogue, read by this device, with
/// `apps.install` behind it — and no list of what the robot has installed.
extension AppStoreModel {
    /// Whether this store is the relay's. Screens word their failures by it: over
    /// the relay it is this device that could not reach Hugging Face, not the robot.
    var isOverRelay: Bool {
        session.canInstallFromCatalogue
    }

    /// The sections this transport can fill. Over the relay that is Discover alone:
    /// nothing there lists what is installed, and an Installed section holding only
    /// this visit's installs would read as everything the robot has.
    var sections: [Section] {
        isOverRelay ? [.discover] : Section.allCases
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
    ///   point, so it is the name to start it by again.
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
        guard isOverRelay else { return nil }
        if let running = runningApp?.app, running.name == app.name || app.matches(installed: running) {
            return running
        }
        return installedOverRelay.contains(app.id) ? app : nil
    }
}
