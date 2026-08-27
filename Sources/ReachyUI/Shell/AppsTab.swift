import ReachyKit
import SwiftUI

/// The store is its own destination rather than a row inside the robot screen: it
/// is somewhere a user goes back to, and a widget can open it directly.
struct AppsTab: View {
    let session: RobotSession
    let router: ReachyRouter
    let runningApp: RunningAppModel
    /// Owned by the shell so the dock's page and this screen are the same page —
    /// see `ReachyTabShell`.
    let store: AppStoreModel
    let install: AppInstallModel
    /// Leaving a relay session is the way back to a robot that can serve the store,
    /// and only the root knows how to do it.
    let findRobot: () -> Void

    var body: some View {
        @Bindable var router = router
        return NavigationStack {
            Group {
                if session.canManageApps {
                    AppStoreScreen(
                        session: session,
                        runningApp: runningApp,
                        model: store,
                        install: install,
                        signIn: { router.showsAccount = true }
                    )
                } else {
                    AppsUnavailableView(isRemote: session.isRemote, findRobot: findRobot)
                }
            }
            .hfAccountToolbar(isPresented: $router.showsAccount)
        }
    }
}
