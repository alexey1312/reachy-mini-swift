import ReachyDesign
import ReachyMedia
import SwiftUI

/// The robot's camera, over the peer connection the relay session already holds.
///
/// `CameraViewport` without its controls, so the connecting, waiting and stalled
/// states read here exactly as they do on the Live tab. Like Pollen's wizard, the
/// confirmation does not wait for a frame: a person looking at the picture is the
/// check, and a black one is worth carrying on past.
struct FirstRunCameraStep: View {
    let model: FirstRunModel
    let camera: CameraSession?

    var body: some View {
        OnboardingStepScaffold(
            title: String(localized: .reachy("Look through its eyes")),
            message: String(localized: .reachy("This is what your robot's camera sees right now. Wave at it."))
        ) {
            Section {
                if let camera {
                    CameraViewport(session: camera)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                } else {
                    ContentUnavailableView(.reachy("No live view"), systemImage: "video.slash")
                }
            } footer: {
                Text(.reachy("The live view stays in the Live tab after setup."))
            }
        } actions: {
            ReachyActionButton(.reachy("I can see it"), fullWidth: true) {
                model.advance()
            }
            FirstRunSkipButton(model: model)
        }
    }
}
