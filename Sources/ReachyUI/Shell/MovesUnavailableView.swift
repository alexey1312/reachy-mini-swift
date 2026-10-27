import ReachyDesign
import SwiftUI

/// The move library is `/api/move/play/*` and the dataset index beside it, both
/// HTTP-only. A relay session carries the robot's commands and its camera and can
/// play an *uploaded* move, but nothing out of the robot's own library — so this
/// names the reason instead of offering a list that would always be empty.
struct MovesUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label(.reachy("Moves need the local network"), systemImage: "music.note")
        } description: {
            Text(.reachy("Connect on the same network as the robot to play its recorded moves."))
        }
        .reachyClearOfFold()
        .navigationTitle(.reachy("Moves"))
    }
}
