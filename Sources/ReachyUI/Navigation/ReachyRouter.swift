import Observation
import ReachyKit
import SwiftUI

/// Where the interface is, and what is presented over it.
///
/// The five tabs are unconditional. A tab that comes and goes forces the shell to
/// second-guess the selection — the old Live tab existed only on a compact width
/// behind a running backend, so its disappearance had to be caught and the
/// selection dragged elsewhere. A tab that is always there renders its own
/// unavailable state instead, which is a thing the user can read.
@MainActor
@Observable
final class ReachyRouter {
    /// The raw values are the Handoff wire spelling (`ReachyHandoff`), so they may not
    /// be renamed without breaking a continuation from an older build.
    enum Tab: String, Hashable, CaseIterable {
        case robot
        case live
        case moves
        case apps
        case settings
    }

    var tab: Tab

    /// The two ways to reach a robot are two entry points to one list, so it is
    /// presented from the root rather than owned by either screen that offers it.
    var showsRemoteRobots = false
    /// The account button sits in every tab's bar and they all open the same sheet,
    /// so the state is here and the sheet is mounted once.
    var showsAccount = false
    /// Privacy permissions. Presented from the root for the same reason as the list
    /// above: the connection screen needs it — two of the three permissions are what
    /// connecting takes — and the Settings tab, which also offers it, does not exist
    /// until a robot has answered.
    var showsPermissions = false

    init(tab: Tab = .robot) {
        self.tab = tab
    }

    /// Moves the selection only. A link that also has to *do* something —
    /// `.runningApp` expands the dock — is completed by the caller, which is what
    /// keeps this type free of the models it would otherwise have to hold.
    func follow(_ link: ReachyDeepLink) {
        switch link {
        case .robot:
            tab = .robot
        // `.runningApp` lands here too: it is the tab under the sheet, and where
        // the request goes if there is no running app to open — which is where
        // someone who asked for one would look for it anyway.
        case .apps, .runningApp:
            tab = .apps
        }
    }
}
