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
    ///
    /// It reaches **both** renderers, but not on the same terms: the camera takes
    /// it from every host that has one, while the scene takes it only from a
    /// source that drives its own model (`ViewportModel.offersSceneTeleop`). The
    /// gate is here and not at the call sites because one factory feeds both
    /// branches — withholding it up there would take the camera's joystick away
    /// from a LAN robot along with the scene's.
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
                    SceneViewport(
                        model: sceneModel,
                        makeTeleop: model.offersSceneTeleop ? makeTeleop : nil,
                        standDown: model.offersSceneTeleop ? standDown : nil
                    )
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

/// The pad, and beside it the way back from where the pad can leave you.
///
/// One cluster for two renderers. It floats over the picture rather than sitting
/// in `ViewportView`'s control cluster: that one is built a level up and does not
/// own this driver, and here the pad lands under the thumb that just turned the
/// robot. Each host decides *whether* to mount it — see `CameraViewport` and
/// `SceneViewport` — and this type decides what it looks like once mounted.
///
/// **An overlay, and it used to be a bottom `safeAreaInset`.** An inset is
/// subtracted from the renderer's rectangle, and this one costs a fixed
/// 140 + 2 × 16 = 172 pt of *height* — nothing on a portrait iPhone's 874, two
/// thirds of a landscape one's 402. With the navigation and tab bars taking
/// their own share, the camera was left ~86 pt to letterbox 16:9 into and
/// rendered a 145 × 80 pt picture in the middle of an 874 pt screen. Nothing
/// moves by drawing it over instead: the pad's own rectangle is
/// `bottom − 156 … bottom − 16` either way.
///
/// It is the same symptom `CameraVideoView`'s doc comment describes and a
/// different cause; that one was the renderer's intrinsic size, and it is fixed.
/// Measure the rectangle the picture is handed before reaching for it.
struct TeleopPadCluster: View {
    let driver: TeleopDriver
    /// Called on the pad's first deflection, so the robot's own head behaviours let
    /// go before this one starts driving. `nil` leaves them alone, which is what a
    /// preview and the floating window both want.
    var standDown: TeleopStandDown?

    var body: some View {
        HStack(spacing: Space.md) {
            recenterButton
            JoystickPad(mapping: driver.mapping) { deflection in
                driver.apply(deflection)
                standDown?()
            }
            .frame(width: Metrics.joystickPad, height: Metrics.joystickPad)
        }
        .padding()
        .animation(Motion.stateChange, value: driver.isBodyTurned)
    }

    /// Offered only once the body is actually turned — at neutral there is nothing
    /// to return from, and neither renderer has another readout of where the robot
    /// is facing, so the button appearing *is* the notice that it has been left off
    /// centre.
    ///
    /// The return is smooth without anything here doing so: `reset()` moves a
    /// goal, and both transports walk their emitted pose toward it under
    /// `TargetSlewLimiter`. Easing it a second time on this side would fight the
    /// pacer that already does it.
    @ViewBuilder
    private var recenterButton: some View {
        if driver.isBodyTurned {
            Button {
                driver.reset()
            } label: {
                Label(.reachy("Reset to neutral"), systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(ViewportControlButtonStyle())
            .transition(.scale.combined(with: .opacity))
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
