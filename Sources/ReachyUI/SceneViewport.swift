import ReachyDesign
import ReachyScene
import SwiftUI

/// The 3D robot inside the viewport. Read-only: it mirrors the state stream and
/// never sends a command.
struct SceneViewport: View {
    let model: RobotSceneModel

    var body: some View {
        RobotSceneView(model: model)
            .overlay(alignment: .center) { status }
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
