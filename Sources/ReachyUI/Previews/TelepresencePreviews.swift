import ReachyKit
@testable import ReachyUI
import SwiftUI

// The sheet the viewport's Presence button opens: the robot's audio levels and the
// two behaviours the daemon runs on its own.

#Preview("Presence — idle") {
    PreviewScene.telepresence(presence: .preview())
}

#Preview("Presence — both on") {
    PreviewScene.telepresence(presence: .preview(wobbling: true, tracking: true))
}

// The slider appears only under a switch that is on, because the daemon takes the weight
// as a parameter of enabling — there is no route that sets it alone. Half strength is the
// state worth a picture: at 100% the row says nothing the label does not.
#Preview("Presence — following at half strength") {
    PreviewScene.telepresence(presence: .preview(tracking: true, weight: 0.5))
}

// The one reading in this section, in both of its states. It reports whether the robot
// has a face to follow and nothing about the switch above — a tracker watching an empty
// room looks exactly like one that is off, which is the confusion the line ends.
#Preview("Presence — a face in view") {
    PreviewScene.telepresence(presence: .preview(tracking: true, seesFace: true))
}

#Preview("Presence — nobody in view") {
    PreviewScene.telepresence(presence: .preview(tracking: true, seesFace: false))
}

// A robot with no camera answers `enabled: false` under a 200, so the switch springs
// back and the section says why rather than leaving a claim on screen.
#Preview("Presence — no camera for tracking") {
    PreviewScene.telepresence(
        presence: .preview(error: "This robot has no camera available for face tracking.")
    )
}

// Over the relay the media routes do not exist, so the section is absent rather than
// offered inert — and only a capture can show that the audio half survives it.
#Preview("Presence — over the relay") {
    PreviewScene.telepresence(
        .preview(address: nil, link: .remote, client: PreviewRemoteRobotClient()),
        presence: .preview()
    )
}

// The Call section, which appears only with a viewport behind the sheet. It scales
// this device's voice on the way to the robot — the one control over a call that
// drowns out everything else the robot plays.
#Preview("Telepresence — your voice") {
    PreviewScene.telepresence(presence: .preview(), viewport: .preview())
}

#Preview("Telepresence — voice turned down") {
    PreviewScene.telepresence(presence: .preview(), viewport: .preview(callMicVolume: 0.4))
}
