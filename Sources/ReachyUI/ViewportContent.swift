import ReachyDesign
import ReachyKit
import SwiftUI

/// The live view of the robot with nothing around it — the renderer, and whatever
/// stands in for it while there is none.
///
/// Split out of `ViewportView` because the chrome does not survive the trip: a
/// segmented picker up to 240 pt wide does not fit a 160 pt window. Both hosts
/// draw this and bring their own controls, which is also what keeps the guarantee
/// readable — there is one renderer, mounted in one place at a time.
struct ViewportContent: View {
    let model: ViewportModel
    /// `nil` where this host offers no teleop at all — over the relay, and in the
    /// floating window, where the robot is watched rather than driven.
    var makeTeleop: TeleopFactory?
    /// Travels beside `makeTeleop` and is `nil` in the same places: only the host that
    /// offers a joystick has anything to hand the head over from.
    var standDown: TeleopStandDown?

    var body: some View {
        if let setupError = model.setupError {
            ContentUnavailableView(
                .reachy("Viewport unavailable"),
                systemImage: "exclamationmark.triangle",
                description: Text(setupError)
            )
        } else {
            switch model.content {
            case .scene:
                if let reason = model.sceneUnavailableReason {
                    // A reason, not a wait: nothing is coming, so a spinner here
                    // would never resolve.
                    ContentUnavailableView(
                        .reachy("No 3D model"),
                        systemImage: "cube.transparent",
                        description: Text(reason)
                    )
                } else if let sceneModel = model.sceneModel {
                    SceneViewport(model: sceneModel)
                } else {
                    ViewportStatus.loading("Connecting…", progress: nil)
                }
            case .camera:
                if let session = model.cameraSession {
                    CameraViewport(session: session, makeTeleop: makeTeleop, standDown: standDown)
                } else {
                    ViewportStatus.loading("Connecting…", progress: nil)
                }
            }
        }
    }
}

/// What the viewport can be switched between here. Shared, because the tab draws
/// a segmented picker over it and the floating window two icons, and a control
/// that appears in one and not the other would be a fork nobody asked for.
enum ViewportOptions {
    @MainActor
    static func offered(by model: ViewportModel, offersCamera: Bool) -> [ViewportModel.Content] {
        (model.offersScene ? [.scene] : []) + (offersCamera ? [.camera] : [])
    }
}
