import ReachyScene
@testable import ReachyUI
import SwiftUI

// `.ready` renders a bare `RealityView`, which produces nothing meaningful in a headless
// snapshot — so it is captured only where it draws chrome of its own, which is the
// simulator's joystick below. Every phase that draws an overlay is covered.

#Preview("Scene — reading the description") {
    PreviewScene.pane { SceneViewport(model: .preview(.fetchingDescription)) }
}

#Preview("Scene — downloading meshes") {
    PreviewScene.pane { SceneViewport(model: .preview(.downloadingMeshes(completed: 3, total: 47))) }
}

#Preview("Scene — almost downloaded") {
    PreviewScene.pane { SceneViewport(model: .preview(.downloadingMeshes(completed: 46, total: 47))) }
}

#Preview("Scene — building") {
    PreviewScene.pane { SceneViewport(model: .preview(.buildingScene)) }
}

#Preview("Scene — failed") {
    PreviewScene.pane { SceneViewport(model: .preview(.failed("The robot served no URDF."))) }
}

// Only the simulator gets a pad over its model, and this is the one image of it. Like
// `Camera — facing forward`, the picture under the controls is blank in a headless
// capture and the controls are the point: the pad bottom-trailing, the recentre button
// absent until the body is actually turned.
#Preview("Scene — simulator joystick") {
    PreviewScene.pane {
        SceneViewport(model: .preview(.ready), makeTeleop: PreviewScene.teleopFactory)
    }
}
