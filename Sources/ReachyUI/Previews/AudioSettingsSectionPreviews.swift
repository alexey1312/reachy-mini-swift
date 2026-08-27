import ReachyKit
@testable import ReachyUI
import SwiftUI

#Preview("Audio — both devices") {
    PreviewScene.audioSection()
}

#Preview("Audio — loading") {
    PreviewScene.audioSection(.preview(speaker: nil, microphone: nil, isLoading: true))
}

// A robot with no microphone still reports a speaker; the missing slider is disabled rather than
// hidden, so the section does not change shape between robots.
#Preview("Audio — speaker only") {
    PreviewScene.audioSection(.preview(microphone: nil))
}

#Preview("Audio — busy") {
    PreviewScene.audioSection(.preview(isBusy: true))
}

#Preview("Audio — error") {
    PreviewScene.audioSection(.preview(errorMessage: "The daemon has no audio device."))
}

// The sheet titles itself, so the section drops its own header there.
#Preview("Audio — sheet variant") {
    PreviewScene.audioSection(.preview(), header: nil)
}

// The three profiles the picker offers. Each is one set of audio-board registers,
// and the caption under the row is the only place their difference is legible.
#Preview("Audio — sensitive profile") {
    PreviewScene.audioSection(.preview(profile: .sensitive))
}

#Preview("Audio — noisy profile") {
    PreviewScene.audioSection(.preview(profile: .noisy))
}

// A board somebody tuned by hand, over the API or with the XMOS tool. The row
// reports it and offers the three profiles beside it; it never overwrites silently.
#Preview("Audio — custom profile") {
    PreviewScene.audioSection(.preview(profile: nil))
}

// No audio board answered, or the session is a relay that carries no such route.
// The levels stay; the profile row is absent rather than disabled, because there is
// nothing to read back and nothing to write.
#Preview("Audio — no audio board") {
    PreviewScene.audioSection(.preview(profile: nil, canTuneProfile: false))
}
