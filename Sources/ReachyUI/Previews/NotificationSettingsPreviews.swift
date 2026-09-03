import ReachyKit
@testable import ReachyUI
import SwiftUI

// Off, which is where every reader starts: an app that has never asked must not look
// as though it had.
#Preview("Notifications — off") {
    PreviewScene.notificationSettings(on: false, authorization: .undetermined)
}

// On and allowed. The footer is the whole reference here — it is the sentence this
// feature can most easily lie about, and English truncation is the only kind a
// reference can catch.
#Preview("Notifications — on") {
    PreviewScene.notificationSettings(on: true)
}

// The state the switch cannot fix by itself: on, and the system refusing. The row
// grows a way out rather than silently doing nothing, which is the failure the whole
// privacy screen exists to end.
#Preview("Notifications — blocked in Settings") {
    PreviewScene.notificationSettings(on: true, authorization: .denied)
}
