import ReachyKit
import SwiftUI

/// The wobbling switch, on the two screens that have a reason to show it: the Presence
/// sheet inside the viewport, and the soundboard where the sound it moves to is played.
///
/// One view rather than two toggles, because the label and the glyph must not drift —
/// two spellings of the same setting read as two settings, and this one cannot be read
/// back from the robot to disprove that.
struct MoveWhileSpeakingToggle: View {
    let session: RobotSession
    let presence: PresenceModel

    var body: some View {
        Toggle(isOn: wobbling) {
            Label(.reachy("Move while speaking"), systemImage: "waveform")
        }
        .disabled(presence.busy)
    }

    /// A binding rather than `$presence.isWobbling`: the setter is a call that can be
    /// refused, and the model writes the flag only once the robot has accepted it.
    private var wobbling: Binding<Bool> {
        Binding(
            get: { presence.isWobbling },
            set: { value in Task { await presence.setWobbling(value, session: session) } }
        )
    }
}
