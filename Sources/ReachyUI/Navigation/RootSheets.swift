import HuggingFaceAuth
import ReachyDesign
import ReachyKit
import SwiftUI

/// The sheets the whole interface shares, mounted once above both the gate and the
/// shell so that connecting — which throws the tree below it away — does not
/// dismiss one mid-flight.
///
/// **Nothing stateful may be constructed in a sheet's content closure.** SwiftUI
/// re-runs that closure on every update of the view the sheet hangs off, which
/// here means every `RobotSession.phase` change — and the candidate sweep produces
/// one every 10 s while the gate is up. Whatever a model was holding is thrown
/// away with it, and a `.task` that filled it does not run a second time. Both
/// models below are therefore handed in already built: `remoteRobots` by the root,
/// `HFSignInModel` by `HFAccountSection`, which adopts the first one it is given
/// into `@State` and ignores every replacement.
struct RootSheets: ViewModifier {
    let session: RobotSession
    let hfAccount: HFAccount
    let remoteRobots: YourReachiesModel
    let router: ReachyRouter
    let connect: (CentralRobot) -> Void

    func body(content: Content) -> some View {
        @Bindable var router = router
        return content
            .sheet(isPresented: $router.showsAccount) {
                NavigationStack {
                    HFSignInScreen(session: session, model: HFSignInModel(account: hfAccount))
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(.reachy("Done")) { router.showsAccount = false }
                            }
                        }
                }
                .reachySheet()
            }
            .sheet(isPresented: $router.showsRemoteRobots) {
                NavigationStack {
                    YourReachiesScreen(
                        model: remoteRobots,
                        connect: connect,
                        // Pushed inside this sheet rather than sending the user to
                        // the robot's Settings tab: that tab does not exist until a
                        // robot is connected — exactly the case that brings anyone
                        // here.
                        signIn: { HFSignInScreen(session: session, model: HFSignInModel(account: hfAccount)) }
                    )
                }
                .reachySheet()
            }
            .sheet(isPresented: $router.showsPermissions) {
                NavigationStack {
                    // Only a LAN session proves the local network was granted; a relay
                    // session proves the opposite is possible, which is half the reason
                    // this screen is reachable from the gate at all.
                    PermissionsScreen(localNetworkProvenByConnection: isConnectedOverLAN)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(.reachy("Done")) { router.showsPermissions = false }
                            }
                        }
                }
                .reachySheet()
            }
    }

    private var isConnectedOverLAN: Bool {
        switch session.link {
        case .lan: true
        // A relay session proves nothing about the local network, and `.none` proves
        // less — which is the case this sheet is reachable from the gate for. A
        // simulator never asked for the network at all.
        case .none, .remote, .simulated: false
        }
    }
}
