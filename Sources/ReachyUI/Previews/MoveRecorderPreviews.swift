import ReachyKit
@testable import ReachyUI
import SwiftUI

// Recording a move from the phone, and the takes it leaves behind.

#Preview("Controller — recording") {
    PreviewScene.controller(
        .preview(),
        recorder: .preview(isRecording: true, elapsed: 3.4)
    )
}

// The takes live above the robot's own libraries, and only once there are any — the
// section's absence is what every other `Moves —` reference already captures.
#Preview("Moves — with recordings") {
    PreviewScene.movesScreen(
        .preview(),
        recorder: .preview(recordings: [
            .preview(name: "Hello wave", seconds: 4.2),
            .preview(name: "Looking around", seconds: 11.8, at: Date(timeIntervalSince1970: 1_769_990_000)),
        ])
    )
}

// A sleeping robot swallows every target without reporting it, so the rows go out
// rather than play into nothing.
#Preview("Moves — recordings, robot asleep") {
    PreviewScene.movesScreen(
        .preview(status: .preview(motorMode: .disabled)),
        recorder: .preview(recordings: [.preview()])
    )
}
