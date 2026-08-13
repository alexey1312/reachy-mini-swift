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
