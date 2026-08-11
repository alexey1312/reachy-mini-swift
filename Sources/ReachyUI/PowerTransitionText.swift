import ReachyDesign
import ReachyKit
import SwiftUI

/// A power transition in flight, wherever one can be started.
///
/// Two screens can start one now — the Robot tab's ladder, and Start on an app's
/// page, which wakes a sleeping robot before it launches anything. Both owe the
/// reader the same sentence, because seconds of nothing read as a button that did
/// not work.
struct PowerTransitionRow: View {
    let transition: RobotSession.PowerTransition

    var body: some View {
        HStack {
            ProgressView()
            Text(transition.statusText)
                .foregroundStyle(.secondary)
        }
    }
}

extension RobotSession.PowerTransition {
    /// Starting a cold backend can take up to 90 s — silence would read as a hang.
    /// Shared by the connection stepper and the connected-robot screen, which can
    /// both be showing a backend start.
    var statusText: String {
        switch self {
        case .startingBackend: String(localized: .reachy("Starting the robot backend… this can take a minute"))
        // Says the sleep out loud because it is the part the reader can see: the
        // robot parks its head first and the backend goes only after that.
        case .stoppingBackend: String(localized: .reachy("Powering off… going to sleep first"))
        case .wakingUp: String(localized: .reachy("Waking up…"))
        case .goingToSleep: String(localized: .reachy("Going to sleep…"))
        }
    }
}
