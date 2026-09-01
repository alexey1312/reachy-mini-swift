import ReachyDesign
import ReachyKit
import SwiftUI

/// Why the app store is not showing, when it is not showing.
///
/// Two genuinely different reasons, which this used to collapse into one wrong
/// sentence. A relay session *is* connected — telling its user "no robot
/// connected" sent them looking for a connection problem they did not have, and
/// the "Your Reachies" button offered as the way out led straight back to the
/// state they were already in.
///
/// And the store is not merely unreached over the relay: the data channel carries
/// no app command at all and the daemon's HTTP API is not exposed outside its
/// network, so the local network is the only way in. Saying so is the honest
/// alternative to an action that cannot work.
struct AppsUnavailableView: View {
    let isRemote: Bool
    let findRobot: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "square.grid.2x2")
        } description: {
            Text(message)
        } actions: {
            Button(action: findRobot) {
                Text(isRemote ? String(localized: .reachy("Find it on this network")) :
                    String(localized: .reachy("Find one nearby")))
            }
        }
        .navigationTitle(.reachy("Apps"))
    }

    private var title: String {
        isRemote ? String(localized: .reachy("Apps need the local network")) :
            String(localized: .reachy("No robot connected"))
    }

    private var message: String {
        if isRemote {
            String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "The relay carries the robot's commands and its camera, not its app store. Connect on the same network to browse and install. An app already running still shows below, and can be stopped there."
                )
            )
        } else {
            // The catalogue is served by the daemon, not by the Hub — the robot
            // fetches it — so there is genuinely nothing to show without one.
            String(localized: .reachy("Apps are installed on the robot, so this needs one connected."))
        }
    }
}
