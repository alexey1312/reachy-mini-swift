import ReachyKit

/// Whether Discover can trust the robot's Hub search. The robot searches with its
/// own token, and a robot with none — or with an expired one — gets a search that
/// collapses to `[]`: the daemon catches the 401, and the catalogue quietly loses
/// everything but the curated handful.
extension AppStoreModel {
    /// Reads the robot's own account, gates Discover on it, and answers whether the
    /// robot was linked since the gate went up — a catalogue read behind the gate is
    /// stale.
    ///
    /// This used to put this app's token on the robot whenever the robot read as
    /// signed out. That sent a `write-repos` token over plain HTTP to whatever host
    /// answered `is_logged_in: false`, and asked nobody. Daemon 1.12 signs every
    /// robot out once (pollen-robotics/reachy_mini#1367), so after that update it
    /// would have run against every robot. Linking is now always a step somebody
    /// takes in the account sheet: a device code from 1.10.0, where no token crosses
    /// the network, and this app's token only on a 1.9 robot that has nothing else
    /// (ADR 0003).
    ///
    /// A robot that cannot answer is left alone: unreachable is not signed out.
    func readRobotHFLink(session: RobotSession) async -> Bool {
        guard session.canLinkHuggingFace, let status = try? await session.robotHFAccount() else { return false }
        let wasGated = discoverNeedsHFSignIn
        discoverNeedsHFSignIn = !status.isLoggedIn
        return wasGated && status.isLoggedIn
    }
}
