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

// The legend appears only while a controller is connected, so every preview above is its absence.
#Preview("Controller — game controller") {
    PreviewScene.controller(.preview(), controllerName: "Xbox Wireless Controller")
}

// Head tracking appears only where the device can read headphone motion, so every preview above
// is its absence too. These four hand the hub the state they show.
#Preview("Controller — head tracking offered") {
    PreviewScene.controller(.preview(), headTracking: .off)
}

#Preview("Controller — waiting for headphones") {
    PreviewScene.controller(.preview(), headTracking: .waiting)
}

// The pad and the roll slider go out while a head steers the target they write.
#Preview("Controller — following a head") {
    PreviewScene.controller(
        .preview(),
        driver: TeleopDriver(target: .init(roll: 0.12, pitch: 0.2, yaw: 0.35)),
        headTracking: .following
    )
}

#Preview("Controller — motion access turned off") {
    PreviewScene.controller(.preview(), headTracking: .denied)
}
