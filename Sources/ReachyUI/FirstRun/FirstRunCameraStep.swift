import ReachyDesign
import ReachyMedia
import SwiftUI

/// The robot's camera, over the peer connection the relay session already holds.
///
/// `CameraViewport` without its controls, so the connecting, waiting and stalled
/// states read here exactly as they do on the Live tab. Like Pollen's wizard, the
/// confirmation does not wait for a frame: a person looking at the picture is the
/// check, and a black one is worth carrying on past.
///
/// **With no camera there is nothing to confirm**, so the step says why and offers
/// Continue. On the LAN the picture comes over the data-channel link the root opened
/// to read the flag, and that link can fail to open in its eight seconds; the step
/// used to ask "I can see it" over a "No live view" placeholder.
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
                        .frame(height: Metrics.stepPicture)
                        .listRowInsets(EdgeInsets())
                } else {
                    ContentUnavailableView(
                        .reachy("No live view"),
                        systemImage: "video.slash",
                        description: Text(
                            .reachy(
                                "The video connection to the robot did not open, so there is no picture to check."
                            )
                        )
                    )
                }
            } footer: {
                Text(.reachy("The live view stays in the Live tab after setup."))
            }
        } actions: {
            if camera == nil {
                ReachyActionButton(.reachy("Continue"), fullWidth: true) {
                    model.advance()
                }
            } else {
                ReachyActionButton(.reachy("I can see it"), fullWidth: true) {
                    model.advance()
                }
                FirstRunSkipButton(model: model)
            }
        }
    }
}
