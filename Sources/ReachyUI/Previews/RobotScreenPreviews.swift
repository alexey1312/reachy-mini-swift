import ReachyKit
@testable import ReachyUI
import SwiftUI

#Preview("Robot — connected") {
    PreviewScene.robotScreen(.preview())
}

#Preview("Robot — unreachable") {
    PreviewScene.robotScreen(.preview(phase: .unreachable(.preview)))
}

#Preview("Robot — backend stopped") {
    PreviewScene.robotScreen(.preview(status: .preview(state: .stopped)))
}

#Preview("Robot — motors disabled") {
    PreviewScene.robotScreen(.preview(status: .preview(motorMode: .disabled)))
}

#Preview("Robot — backend fault") {
    PreviewScene.robotScreen(.preview(status: .preview(error: "Power supply not connected")))
}

#Preview("Robot — compatibility warning") {
    PreviewScene.robotScreen(.preview(compatibilityWarning: "Daemon 1.10.0 is newer than the tested baseline 1.9.0."))
}

#Preview("Robot — error") {
    PreviewScene.robotScreen(.preview(error: "Could not connect to the server."))
}

#Preview("Robot — waking up") {
    PreviewScene.robotScreen(.preview(powerTransition: .wakingUp))
}

#Preview("Robot — starting backend") {
    PreviewScene.robotScreen(.preview(powerTransition: .startingBackend))
}

// The whole ladder in its last rung: the daemon parks the robot before it tears
// the backend down, and the caption says so because that is the part the reader
// can watch happen.
#Preview("Robot — powering off") {
    PreviewScene.robotScreen(.preview(powerTransition: .stoppingBackend))
}

// Not covered, deliberately: the power-off `confirmationDialog`. It presents in a
// context of its own that renders as nothing headless — recorded once with and
// once without a running app, the two references came out **byte-identical** and
// identical to this screen without a dialog at all, so neither could tell the
// sentence apart. That sentence is the whole point of the dialog, and it is
// asserted where it can be: `RobotPowerOffModelTests` names the running app
// without rendering anything.

// Every identity field is optional and the daemon may report none of them; the screen falls back
// to em dashes and drops the links whose transport it does not have.
#Preview("Robot — nothing reported") {
    PreviewScene.robotScreen(.preview(phase: .connected(RobotIdentity()), status: nil, address: nil))
}

// The Model row is the app's one positive statement about which kind of robot answered. A Lite
// unit and a simulator both run their daemon on a computer rather than on the robot, and both are
// `wireless_version: false` — what separates them is `simulation_enabled`, which is the whole of
// `RobotSession.flavour`.
#Preview("Robot — Lite robot") {
    PreviewScene.robotScreen(.preview(status: .preview(wirelessVersion: false)))
}

#Preview("Robot — simulator") {
    PreviewScene.robotScreen(.preview(status: .preview(wirelessVersion: false, simulationEnabled: true)))
}

// Over the relay the connection is named rather than addressed, and only the moves are gone: the
// recorded-move library is HTTP-only, while the joystick and the journal both ride the data
// channel. Before this, all three vanished together for want of an address.
#Preview("Robot — over the relay") {
    PreviewScene.robotScreen(.preview(
        address: nil,
        link: .remote,
        client: PreviewRemoteRobotClient()
    ))
}
