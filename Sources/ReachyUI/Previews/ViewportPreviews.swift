import ReachyMedia
import ReachyScene
@testable import ReachyUI
import SwiftUI

#Preview("Viewport — connecting to the scene") {
    PreviewScene.viewport(.preview())
}

#Preview("Viewport — connecting to the camera") {
    PreviewScene.viewport(.preview(content: .camera))
}

#Preview("Viewport — unavailable") {
    PreviewScene.viewport(.preview(setupError: "Could not reach 192.168.1.42"))
}

// A wired robot reports no camera, so there is nothing to switch between and the picker goes away
// rather than sitting there disabled.
#Preview("Viewport — no camera") {
    PreviewScene.viewport(.preview(), offersCamera: false)
}

#Preview("Viewport — scene building") {
    PreviewScene.viewport(.preview(sceneModel: .preview(.buildingScene)))
}

#Preview("Viewport — camera waiting") {
    PreviewScene.viewport(.preview(content: .camera, cameraSession: .preview(.waitingForProducer)))
}

// A refused microphone used to look exactly like a muted one — same glyph, same
// colour, and tapping it did nothing. `ViewportView` owns that button, so the
// reference goes through the whole viewport rather than its camera-only content.
#Preview("Viewport — microphone blocked") {
    let camera = CameraSession.preview(.streaming, micPermission: .denied)
    return PreviewScene.viewport(
        .preview(content: .camera, cameraSession: camera),
        makeTeleop: PreviewScene.teleopFactory
    )
}

// The End button exists only while a call is up, and a call cannot be placed headless —
// `RobotCallController.preview` is the seam. Without this capture the button's absence
// from every other camera reference proves nothing about it being conditional.
#Preview("Viewport — on a call") {
    let camera = CameraSession.preview(.streaming, micPermission: .granted, isMicEnabled: true)
    return PreviewScene.viewport(
        .preview(content: .camera, cameraSession: camera),
        makeTeleop: PreviewScene.teleopFactory,
        onCall: true
    )
}

// Over the relay the URDF and its meshes are out of reach, so the 3D pane says so once instead of
// spinning on a download that is never going to start.
#Preview("Viewport — no 3D over the relay") {
    PreviewScene.viewport(.preview(source: .remote(.preview(.waitingForProducer))))
}

// The direction-of-arrival badge in the chrome row it actually lives in — the
// standalone `Direction of arrival —` references capture the badge, and only this one
// can say it sits beside the switcher rather than under the iPad's floating tab bar.
// Over the camera on purpose: that is the view where a voice off to one side is
// something the picture cannot show.
#Preview("Viewport — heard a voice") {
    PreviewScene.viewport(
        .preview(
            content: .camera,
            cameraSession: .preview(.streaming),
            hearing: .preview(.left)
        )
    )
}

// And with only the camera to show, the switcher is gone rather than offering a dead segment.
#Preview("Viewport — remote camera") {
    let camera = CameraSession.preview(.waitingForProducer)
    return PreviewScene.viewport(
        .preview(content: .camera, cameraSession: camera, source: .remote(camera))
    )
}
