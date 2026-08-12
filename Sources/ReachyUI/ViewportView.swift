import ReachyDesign
import ReachyKit
import SwiftUI

/// Opens a teleop stream on demand — a WebSocket on the LAN, the session's own
/// data channel over the relay.
///
/// `@Sendable` because a `View` is, and this is stored on two of them; `@MainActor`
/// because the session it closes over is.
typealias TeleopFactory = @MainActor @Sendable () throws -> any TeleopChannel

/// The Live tab's host for the viewport: `ViewportContent` under the full-size
/// chrome.
///
/// It is one of two hosts, never both at once. `RobotSceneView` hands the scene's
/// root entity to `RealityView`, and an entity has exactly one parent, so a second
/// mounted viewport would silently steal the robot from the first.
/// `FloatingViewportModel.placement` is what makes "one at a time" structural: this
/// view is drawn only at `.inline`, and `FloatingViewport` only at everything else.
struct ViewportView: View {
    let model: ViewportModel
    /// The robot reports no camera at all on a wired unit — then there is nothing
    /// to switch between and the control is hidden rather than disabled.
    let offersCamera: Bool
    /// `nil` where this connection carries no teleop at all, and then the joystick
    /// is absent rather than inert.
    var makeTeleop: TeleopFactory?

    var body: some View {
        ViewportContent(model: model, makeTeleop: makeTeleop)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { chrome }
    }

    /// Every floating control hugs the leading edge: on iPad the tab bar floats
    /// over the top centre, and anything trailing-aligned ends up underneath it.
    ///
    /// **No `ReachySurfaceGroup` here, and it is not an oversight.** A
    /// `GlassEffectContainer` only sees a `glassEffect` applied to its own
    /// subviews; one nested inside a `.background` — which is where every
    /// `SurfaceRole` puts it — gets hoisted into the container's merged sheet and
    /// composited *over* the content instead of under it. On device that blurred
    /// the switcher's labels and this button's glyph into illegibility, and the
    /// snapshot suite cannot see it because glass does not render headless.
    /// `ReachyDesign/AGENTS.md` carries the measurement.
    private var chrome: some View {
        HStack(spacing: Space.md) {
            switcher
            contentControls
            // Last in the row, and outside `contentControls`, because it belongs to
            // neither engine: the reading is the same fact whichever view is up, and
            // `ViewportModel.hearing` outlives the switch between them.
            if let hearing = model.hearing {
                DirectionOfArrivalIndicator(model: hearing)
            }
        }
        .padding(Space.md)
    }

    @ViewBuilder
    private var contentControls: some View {
        switch model.content {
        case .scene:
            if let sceneModel = model.sceneModel {
                SceneOptionsMenu(model: sceneModel)
            }
        case .camera:
            if let session = model.cameraSession {
                CameraMicButton(session: session)
            }
        }
    }

    /// What there is to switch between. Over the relay the 3D model does not
    /// exist, so there is one option and the control disappears rather than
    /// offering a dead segment.
    private var options: [ViewportModel.Content] {
        ViewportOptions.offered(by: model, offersCamera: offersCamera)
    }

    @ViewBuilder
    private var switcher: some View {
        if options.count > 1 {
            Picker(.reachy("Viewport"), selection: Binding(
                get: { model.content },
                set: { model.setContent($0) }
            )) {
                ForEach(options) { content in
                    Label(content.title, systemImage: content.systemImage).tag(content)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            // A segmented control's track is translucent, so on the camera's black
            // backdrop the unselected segment had no contrast left and read as missing
            // (seen in dark mode). It now carries its own backing like every other
            // floating control here — which is the rule stated at the bottom of this
            // file, and the reason it holds regardless of theme or what is behind it.
            //
            // 3 pt is optical, not rhythm: it is what stops the segmented track from
            // touching the capsule around it.
            .padding(3)
            .reachySurface(.chrome, in: .capsule)
        }
    }
}

/// Shared chrome so the scene and the camera report progress the same way.
enum ViewportStatus {
    /// `@MainActor` because it builds a surface, and `ViewModifier` carries that
    /// isolation in Swift 6.
    @MainActor
    static func loading(_ title: String, progress: Double?) -> some View {
        VStack(spacing: Space.md) {
            if let progress {
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
            } else {
                ProgressView()
            }
            Text(title)
                .font(Typography.detail)
                .foregroundStyle(Tone.quiet.style)
        }
        .padding(20)
        // `Radius.rect` is `.continuous`; this shape used to default to `.circular`,
        // so the reference image moves here. That is the correction, not a
        // regression — `ReachyDesign/AGENTS.md` records it as expected.
        .reachySurface(.chrome, in: Radius.rect(Radius.md))
    }
}

extension View {
    /// Floating controls sit on top of video and 3D alike, so they carry their own
    /// backing rather than relying on whatever is behind them for contrast.
    ///
    /// `@MainActor` because `reachySurface` is: a `ViewModifier`'s initialiser
    /// carries that isolation in Swift 6, and a nonisolated helper cannot return
    /// what it builds.
    @MainActor
    func viewportControlStyle() -> some View {
        font(.title3)
            .padding(Space.sm)
            .reachySurface(.chrome, in: .circle)
    }
}
