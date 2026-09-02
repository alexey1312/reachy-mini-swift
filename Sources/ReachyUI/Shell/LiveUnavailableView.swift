import ReachyDesign
import SwiftUI

/// Why the viewport is empty. Both the geometry and the state stream sit behind
/// the robot's backend, so a connection alone shows nothing.
struct LiveUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            .reachy("No live view"),
            systemImage: "cube.transparent",
            description: Text(.reachy("Start the motors and camera to see the live view."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
