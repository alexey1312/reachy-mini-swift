import ReachyKit
import ReachyMedia
import ReachyScene
@testable import ReachyUI
import SwiftUI

// The first run (#169), one capture per state a step can be in. The twin on the motors step is a
// `RealityView` and renders nothing headless, so those references cover the words around it; the
// gate that holds the wake-up is `FirstRunModelTests`'. The camera's picture is a Metal layer and
// captures black, which is the intended image: the frame and its footer are what can move.

#Preview("First run — welcome") {
    PreviewScene.firstRun(.preview(session: PreviewScene.firstRunSession(), step: .welcome))
}

// MARK: - Name

#Preview("First run — name") {
    PreviewScene.firstRun(.preview(session: PreviewScene.firstRunSession(), step: .name))
}

#Preview("First run — name refused") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(),
        step: .name,
        name: "Kitchen",
        nameError: "The robot did not answer."
    ))
}

#Preview("First run — name too long") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(),
        step: .name,
        name: String(repeating: "Reachy ", count: 10)
    ))
}

// MARK: - Motors

#Preview("First run — reading the motors") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(),
        step: .motors,
        twin: .preview(.ready)
    ))
}

#Preview("First run — motors in place") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(),
        step: .motors,
        poseCheck: .checked(.inPosition),
        twin: .preview(.ready)
    ))
}

#Preview("First run — motors out of place") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(),
        step: .motors,
        poseCheck: .checked(.outOfPosition(misplaced: [.neck3, .rightAntenna], swaps: [])),
        twin: .preview(.ready)
    ))
}

#Preview("First run — motors swapped") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(),
        step: .motors,
        poseCheck: .checked(.outOfPosition(misplaced: [.neck2, .neck5], swaps: [MotorSwap(.neck2, .neck5)])),
        twin: .preview(.ready)
    ))
}

#Preview("First run — motors unreadable") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(),
        step: .motors,
        poseCheck: .checked(.unavailable),
        twin: .preview(.ready)
    ))
}

#Preview("First run — robot already awake") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(awake: true),
        step: .motors,
        poseCheck: .checked(.outOfPosition(misplaced: [.neck1, .neck2, .neck5, .neck6], swaps: [])),
        twin: .preview(.ready)
    ))
}

#Preview("First run — waking up") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(powerTransition: .wakingUp),
        step: .motors,
        poseCheck: .checked(.inPosition),
        twin: .preview(.ready)
    ))
}

#Preview("First run — did it move") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(awake: true),
        step: .motors,
        poseCheck: .checked(.inPosition),
        twin: .preview(.ready),
        hasWoken: true
    ))
}

#Preview("First run — it did not move") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(awake: true),
        step: .motors,
        poseCheck: .checked(.inPosition),
        twin: .preview(.ready),
        hasWoken: true,
        needsHelp: true
    ))
}

// MARK: - Camera, microphone, speaker

#Preview("First run — camera") {
    PreviewScene.firstRun(
        .preview(session: PreviewScene.firstRunSession(awake: true), step: .camera),
        remoteLink: .preview(camera: .preview(.streaming))
    )
}

// No link, so no camera: what a LAN robot shows when its data channel did not open in time.
#Preview("First run — no live view") {
    PreviewScene.firstRun(.preview(session: PreviewScene.firstRunSession(awake: true), step: .camera))
}

#Preview("First run — listening") {
    PreviewScene.firstRun(.preview(session: PreviewScene.firstRunSession(awake: true), step: .microphone))
}

#Preview("First run — heard") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(awake: true),
        step: .microphone,
        hearing: .heard
    ))
}

#Preview("First run — cannot hear") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(awake: true),
        step: .microphone,
        hearing: .unsupported
    ))
}

#Preview("First run — speaker") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(awake: true),
        step: .speaker,
        audio: .preview(speaker: AudioLevel(percent: 40))
    ))
}

#Preview("First run — sound played") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(awake: true),
        step: .speaker,
        hasPlayedSound: true,
        audio: .preview(speaker: AudioLevel(percent: 40))
    ))
}

#Preview("First run — sound not heard") {
    PreviewScene.firstRun(.preview(
        session: PreviewScene.firstRunSession(awake: true),
        step: .speaker,
        hasPlayedSound: true,
        audio: .preview(speaker: AudioLevel(percent: 25)),
        needsHelp: true
    ))
}

#Preview("First run — done") {
    PreviewScene.firstRun(.preview(session: PreviewScene.firstRunSession(awake: true), step: .done))
}
