import ReachyKit
@testable import ReachyUI
import SwiftUI

#Preview("Moves — library loaded") {
    PreviewScene.movesScreen(.preview())
}

#Preview("Moves — dances loading") {
    PreviewScene.movesScreen(.preview(), model: .preview(moves: [], loading: true))
}

#Preview("Moves — emotions loading") {
    PreviewScene.movesScreen(.preview(), model: .preview(moves: [], selection: 1, loading: true))
}

#Preview("Moves — music loading") {
    PreviewScene.movesScreen(.preview(), model: .preview(moves: [], selection: 2, loading: true))
}

#Preview("Moves — empty library") {
    PreviewScene.movesScreen(.preview(), model: .preview(moves: []))
}

#Preview("Moves — emotions selected") {
    PreviewScene.movesScreen(.preview(), model: .preview(selection: 1))
}

#Preview("Moves — music selected") {
    PreviewScene.movesScreen(.preview(), model: .preview(selection: 2))
}

#Preview("Moves — playing") {
    PreviewScene.movesScreen(.preview(moveActivity: .playing(.preview(move: "happy_dance"))))
}

#Preview("Moves — stopping") {
    PreviewScene.movesScreen(.preview(moveActivity: .stopping(.preview(move: "happy_dance"))))
}

// A move found already running on connect. `/api/move/running` answers with UUIDs
// alone, so there is no row to highlight and the strip says so in words.
#Preview("Moves — unidentified playback") {
    PreviewScene.movesScreen(.preview(moveActivity: .playing(.preview(uuid: "adopted"))))
}

// The second the robot spends walking back to zero after a move. No Stop: there is
// nothing left to stop, and cancelling the parking would leave it mid-pose.
#Preview("Moves — returning to neutral") {
    PreviewScene.movesScreen(.preview(moveActivity: .recentring(uuid: "goto-preview")))
}

// Browsing stays available while the robot sleeps; only playback is gated.
#Preview("Moves — asleep") {
    PreviewScene.movesScreen(.preview(status: .preview(motorMode: .disabled)))
}

// The reason lives on the model, not the session: a move the daemon refused is
// this screen's news, and `RobotSession.robotError` now carries connection and
// power alone.
#Preview("Moves — error") {
    PreviewScene.movesScreen(
        .preview(),
        model: .preview(error: "The daemon refused the move: 503 Backend not running.")
    )
}
