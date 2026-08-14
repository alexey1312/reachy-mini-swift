import ReachyDesign
import SwiftUI

/// What the Live tab says on a sidebar when the column already has the picture and
/// this connection carries nothing to drive the robot with.
///
/// It exists because the column took the one thing this tab used to show. Over the
/// relay `canTeleoperate` is false — the data channel carries no `ws/set_target` — so
/// without this the tab would be blank, which reads as a screen that failed to load
/// rather than as a connection that does not offer controls. Its sibling
/// `LiveUnavailableView` answers a different question: that one is "there is no live
/// view at all", this one is "the live view is beside you, and there is nothing here
/// to do with it".
struct ControlsUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            .reachy("No controls"),
            systemImage: "gamecontroller",
            description: Text(.reachy("This connection cannot drive the robot. The live view is in the column."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
