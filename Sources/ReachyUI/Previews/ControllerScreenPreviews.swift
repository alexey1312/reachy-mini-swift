import ReachyKit
@testable import ReachyUI
import SwiftUI

#Preview("Controller — awake, neutral") {
    PreviewScene.controller(.preview())
}

// `yaw` matches `bodyYaw` wherever a preview turns the body: head yaw is world-frame, so a turned
// body with `yaw: 0` is a head left staring at the room — a state the driver no longer produces.

// Every control is disabled while the motors are off, with the banner explaining why: the daemon
// accepts motion commands from an asleep robot and silently does nothing.
#Preview("Controller — asleep") {
    PreviewScene.controller(.preview(status: .preview(motorMode: .disabled)))
}

#Preview("Controller — backend stopped") {
    PreviewScene.controller(.preview(status: .preview(state: .stopped)))
}

#Preview("Controller — displaced") {
    PreviewScene.controller(
        .preview(),
        driver: TeleopDriver(
            target: .init(z: 0.02, roll: 0.35, yaw: 1.2, bodyYaw: 1.2, antennaLeft: -1.1, antennaRight: 0.9)
        )
    )
}

#Preview("Controller — setup failed") {
    PreviewScene.controller(.preview(), setupError: "Could not open ws://192.168.1.42:8000/api/move/ws/set_target")
}
