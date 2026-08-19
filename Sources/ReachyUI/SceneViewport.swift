import ReachyDesign
import ReachyScene
import SwiftUI

/// The 3D robot inside the viewport.
///
/// It mirrors the state stream, and against a real robot that is all it does. The
/// simulator is the exception it now carries a joystick for: there the model *is*
/// the robot, so driving it here is driving the thing itself rather than nudging
/// a picture that the camera would then disagree with. `ViewportContent` is what
/// decides which of the two this is; see `ViewportModel.offersSceneTeleop`.
struct SceneViewport: View {
    let model: RobotSceneModel
    /// `nil` hides the joystick outright rather than showing one that cannot move
    /// anything — which is every source but the simulator.
    var makeTeleop: TeleopFactory?
    /// Travels beside `makeTeleop` and is `nil` in the same places.
    var standDown: TeleopStandDown?

    @State private var driver: TeleopDriver
    @Environment(\.reachyPreviewMode) private var previewMode

    init(
        model: RobotSceneModel,
        makeTeleop: TeleopFactory? = nil,
        standDown: TeleopStandDown? = nil,
        driver: TeleopDriver = TeleopDriver()
    ) {
        self.model = model
        self.makeTeleop = makeTeleop
        self.standDown = standDown
        _driver = State(initialValue: driver)
    }

    var body: some View {
        RobotSceneView(model: model)
            .overlay(alignment: .center) { status }
            .overlay(alignment: .bottomTrailing) { teleopControls }
            .onAppear { connectTeleop() }
            .onDisappear { driver.stop() }
    }

    /// Gated on `.ready` for the reason the camera gates on `.streaming`: until the
    /// meshes are down there is no robot on screen to aim at, and the pad would sit
    /// over a progress bar.
    ///
    /// The pad claims its own circle with `.contentShape`, so the orbit drag that
    /// `RobotSceneView` reads still works everywhere outside it.
    @ViewBuilder
    private var teleopControls: some View {
        if model.phase == .ready, makeTeleop != nil {
            TeleopPadCluster(driver: driver, standDown: standDown)
        }
    }

    private func connectTeleop() {
        guard !previewMode, let makeTeleop else { return }
        try? driver.start(makeTeleop)
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle, .fetchingDescription:
            ViewportStatus.loading(String(localized: .reachy("Reading the robot's description…")), progress: nil)
        case let .downloadingMeshes(completed, total):
            // The first visit pulls every mesh over the robot's own Wi-Fi, which
            // is slow enough that a bare spinner reads as a hang.
            ViewportStatus.loading(
                String(localized: .reachy("Downloading model \(completed)/\(total)…")),
                progress: total > 0 ? Double(completed) / Double(total) : nil
            )
        case .buildingScene:
            ViewportStatus.loading(String(localized: .reachy("Building the scene…")), progress: nil)
        case .ready:
            EmptyView()
        case let .failed(message):
            ContentUnavailableView(
                .reachy("Could not load the model"),
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}

/// Lives beside the viewport switcher rather than inside the scene, so the
/// floating controls stay in one cluster.
struct SceneOptionsMenu: View {
    let model: RobotSceneModel

    var body: some View {
        Menu {
            Button {
                model.camera.reset()
            } label: {
                Label(.reachy("Reset view"), systemImage: "arrow.counterclockwise")
            }
            Divider()
            Toggle(.reachy("Place head from pose"), isOn: Binding(
                get: { model.placesHeadDirectly },
                set: { model.placesHeadDirectly = $0 }
            ))
            Toggle(.reachy("Solve Stewart linkage"), isOn: Binding(
                get: { model.solvesPassiveJoints },
                set: { model.solvesPassiveJoints = $0 }
            ))
            if let lastFrameAt = model.lastFrameAt {
                Text(.reachy("Last frame \(lastFrameAt.formatted(date: .omitted, time: .standard))"))
            }
            Text(.reachy("Decoded frames: \(model.streamDiagnostics.decodedFrames)"))
        } label: {
            Label(.reachy("Options"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .viewportControlLabelStyle()
        }
        .viewportControlMenuStyle()
    }
}
