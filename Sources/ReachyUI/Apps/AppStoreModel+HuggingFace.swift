import ReachyKit

/// Keeping the robot's Hugging Face session alive, because nothing on the robot
/// can: the daemon stores only the access half of the OAuth token and searches the
/// Hub with it. Once that expires the search collapses to `[]` — the daemon catches
/// the 401 — and the catalogue quietly loses everything but the curated handful.
extension AppStoreModel {
    /// Puts a live Hugging Face token back on the robot, and answers whether it had
    /// to — a catalogue read behind an expired token is stale.
    ///
    /// The daemon keeps only the access half and cannot renew it, so this app is the
    /// only party that can. A robot that cannot answer at all is left alone:
    /// unreachable is not signed out. The outcome is read back from the session's
    /// own cache rather than from `linkRobot`, which throws when the relay half
    /// fails — by then the token is saved and the account is known.
    func relinkHuggingFace(session: RobotSession, token: @MainActor () async -> String?) async -> Bool {
        guard session.canLinkHuggingFace, let status = try? await session.robotHFAccount() else { return false }
        guard !status.isLoggedIn else {
            discoverNeedsHFSignIn = false
            return false
        }
        guard let token = await token() else {
            discoverNeedsHFSignIn = true
            return false
        }
        _ = try? await session.linkRobot(token: token)
        let linked = await (try? session.robotHFAccount())?.isLoggedIn == true
        discoverNeedsHFSignIn = !linked
        return linked
    }
}
