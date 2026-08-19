import ReachyMedia
@testable import ReachyUI
import SwiftUI

// The video layer is a Metal-backed `RTCMTLVideoView` and captures as an empty rectangle, so the
// three phases that draw an overlay carry this screen's cover. `.streaming` is here anyway, twice:
// its chrome is not the video and does render, and the return-to-neutral button is conditional —
// a reference for the turned state alone could not tell it apart from a permanent one. Expect a
// black frame with controls on it, which is exactly what is under test.

#Preview("Camera — connecting") {
    PreviewScene.pane {
        CameraViewport(session: .preview(.connecting))
    }
}

#Preview("Camera — waiting for producer") {
    PreviewScene.pane {
        CameraViewport(session: .preview(.waitingForProducer))
    }
}

#Preview("Camera — unavailable") {
    PreviewScene.pane {
        CameraViewport(session: .preview(.failed("The robot closed the signaling socket.")))
    }
}

#Preview("Camera — facing forward") {
    PreviewScene.pane {
        CameraViewport(session: .preview(.streaming), makeTeleop: PreviewScene.teleopFactory)
    }
}

#Preview("Camera — body turned") {
    PreviewScene.pane {
        CameraViewport(session: .preview(.streaming))
            .overlay(alignment: .bottomTrailing) {
                TeleopPadCluster(
                    isVisible: true,
                    makeTeleop: PreviewScene.teleopFactory,
                    // `yaw` follows `bodyYaw`: head yaw is world-frame, so a turned body with
                    // `yaw: 0` is a head left staring at the room rather than down its own torso.
                    driver: TeleopDriver(target: .init(yaw: 1.2, bodyYaw: 1.2))
                )
            }
    }
}
