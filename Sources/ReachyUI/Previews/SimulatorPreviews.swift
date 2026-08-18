@testable import ReachyUI
import SwiftUI

// The fourth segment, and the only one that offers a robot rather than a way to
// reach one. Standalone rather than as states of `Connection —` for the reason
// `Local daemon —` is: both are sections, and the segment they sit under is a
// picker a capture of the screen shows in only one position anyway.
//
// The two states are worth separating because the disabled one is what a reader
// sees for the seconds a connection takes, and a capture of the ready state alone
// cannot tell a button that dims from one that never does.

#Preview("Simulator — ready") {
    PreviewScene.simulatorSection()
}

#Preview("Simulator — connecting") {
    PreviewScene.simulatorSection(isConnecting: true)
}
