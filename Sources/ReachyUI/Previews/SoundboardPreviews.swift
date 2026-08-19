import ReachyKit
@testable import ReachyUI
import SwiftUI

#Preview("Sounds — in both libraries") {
    PreviewScene.soundboard(.preview())
}

// After a robot restart every sound is on this device and none is on the robot, which
// is the state the "Send n to the robot" row exists for. It is the ordinary state, not
// an edge case: uploads live in `/tmp`.
#Preview("Sounds — nothing sent yet") {
    PreviewScene.soundboard(
        .preview(),
        model: .preview(rows: SoundboardModel.previewDeviceOnlyRows)
    )
}

// The robot could not be asked, so no row claims anything about it. The reason is in
// the error section rather than in the captions.
#Preview("Sounds — robot did not answer") {
    PreviewScene.soundboard(
        .preview(),
        model: .preview(
            rows: SoundboardModel.previewUnknownRows,
            hasListed: false,
            error: "The daemon rejected the request (HTTP 503)"
        )
    )
}

#Preview("Sounds — empty") {
    PreviewScene.soundboard(.preview(), model: .preview(rows: []))
}

// Never answered, as opposed to answered with nothing — without the distinction the
// first frame would claim an empty library before anything had been asked.
#Preview("Sounds — asking the robot") {
    PreviewScene.soundboard(
        .preview(),
        model: .preview(rows: [], hasListed: false, loading: true)
    )
}

#Preview("Sounds — sending one") {
    PreviewScene.soundboard(
        .preview(),
        model: .preview(rows: SoundboardModel.previewDeviceOnlyRows, busy: "rimshot.ogg")
    )
}

// A caption that says a sound *was* played. Nothing reports whether one is playing, so
// there is deliberately no state here that claims it is.
#Preview("Sounds — last played") {
    PreviewScene.soundboard(.preview(), model: .preview(lastPlayed: "airhorn.wav"))
}

// Playing is the one thing here that needs a backend, so this is the state where the
// rows go inert and the banner says why. Sending and deleting still work.
#Preview("Sounds — backend stopped") {
    PreviewScene.soundboard(.preview(status: .preview(state: .stopped)))
}

// The reason belongs to this screen's model: `robotError` is the robot's connection and
// power, and a refused sound is neither.
#Preview("Sounds — refused") {
    PreviewScene.soundboard(
        .preview(),
        model: .preview(error: "Unsupported or invalid audio file (HTTP 400)")
    )
}

// The switch this screen borrows from the Presence sheet, on. Every other capture here
// has it off, so nothing else shows what the row looks like once the head is moving.
#Preview("Sounds — moving while speaking") {
    PreviewScene.soundboard(.preview(), presence: .preview(wobbling: true))
}
