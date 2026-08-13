import ReachyKit
@testable import ReachyUI
import SwiftUI

// MARK: - Getting a link

#Preview("Recovery — scanning") {
    PreviewScene.bleConsole(.preview(stage: .scanning))
}

#Preview("Recovery — robots found") {
    PreviewScene.bleConsole(.preview(
        stage: .scanning,
        link: .preview(discovered: [.previewNear, .previewFar])
    ))
}

// What an advertisement adds to a scan, in the three shapes it comes in: a robot
// sending the block upstream describes, one sending somebody else's (printed as hex
// rather than decoded), and one sending none — which is every robot seen so far, and
// what `Recovery — robots found` above already captures.
#Preview("Recovery — advertised identity") {
    PreviewScene.bleConsole(.preview(
        stage: .scanning,
        link: .preview(discovered: [.previewAdvertising, .previewUnknownAdvert, .previewNear])
    ))
}

#Preview("Recovery — Bluetooth off") {
    PreviewScene.bleConsole(.preview(stage: .scanning, link: .preview(availability: .poweredOff)))
}

#Preview("Recovery — no Bluetooth hardware") {
    PreviewScene.bleConsole(.preview(stage: .scanning, link: .preview(availability: .unsupported)))
}

#Preview("Recovery — connect failed") {
    PreviewScene.bleConsole(.preview(
        stage: .scanning,
        link: .preview(discovered: [.previewNear]),
        errorMessage: "The robot did not answer in time."
    ))
}

// MARK: - Linked

// The journal reads without the code, which is the point: a robot too broken to unlock is
// exactly the one whose log is worth reading.
#Preview("Recovery — journal, locked") {
    PreviewScene.bleConsole(.preview(stage: .locked, log: PreviewScene.journalLines))
}

#Preview("Recovery — journal, quiet robot") {
    PreviewScene.bleConsole(.preview(stage: .unlocked))
}

// The robot's own `journalctl` exited. The lines already collected stay on screen — that is why
// the console passes no `failure:` to `LogConsoleView`.
#Preview("Recovery — journal stopped") {
    PreviewScene.bleConsole(.preview(
        stage: .locked,
        journalFailure: "Journal not running",
        log: PreviewScene.journalLines
    ))
}

// MARK: - Commands

#Preview("Recovery commands — locked") {
    PreviewScene.commands(.preview(stage: .locked))
}

#Preview("Recovery commands — unlocked") {
    PreviewScene.commands(.preview(stage: .unlocked))
}

#Preview("Recovery commands — wrong code") {
    PreviewScene.commands(.preview(stage: .locked, errorMessage: "Incorrect PIN"))
}

// An older daemon whose `commands/` directory is empty answers the literal `None`.
#Preview("Recovery commands — none offered") {
    PreviewScene.commands(.preview(stage: .unlocked, scripts: []))
}

// MARK: - Software reset

#Preview("Software reset — gates") {
    PreviewScene.softwareReset(.preview(stage: .unlocked))
}

// All four gates satisfied, so the button is armed and counting down.
#Preview("Software reset — armed") {
    PreviewScene.softwareReset(
        .preview(stage: .unlocked),
        acknowledged: true,
        typedID: "a1b2c3d4e5f60718",
        code: "4A7f9"
    )
}

// A robot that never reported an id cannot be confirmed, so the gate can never pass.
#Preview("Software reset — no hardware id") {
    PreviewScene.softwareReset(.preview(stage: .unlocked, link: .preview(hardwareID: nil)))
}

#Preview("Software reset — restoring") {
    PreviewScene.softwareReset(
        .preview(stage: .locked),
        dispatched: true,
        stillAnswering: true
    )
}

// The Bluetooth unit is separate from the daemon and stays up throughout, so no answer here is
// worth showing differently from a healthy reset.
#Preview("Software reset — no answer") {
    PreviewScene.softwareReset(
        .preview(stage: .locked),
        dispatched: true,
        stillAnswering: false
    )
}
