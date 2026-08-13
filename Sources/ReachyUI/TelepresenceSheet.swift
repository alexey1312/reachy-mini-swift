import ReachyDesign
import ReachyKit
import SwiftUI

/// Everything about being *there* through the robot, from inside the viewport: how
/// loud it speaks, how well it hears, and whether it moves like something alive.
///
/// A sheet from the viewport rather than rows on the Settings tab. Both halves are
/// things a reader wants **while looking through the camera** — the speaker is too
/// quiet in the room you are calling into, the robot is holding too still — and
/// leaving the Live tab to reach them means giving up the stream to change it.
/// `AudioSettingsSection` is reused whole rather than restyled; it is the same
/// section the Settings tab draws.
struct TelepresenceSheet: View {
    let session: RobotSession
    let dismiss: () -> Void

    @State private var presence: PresenceModel
    @State private var audio: AudioSettingsModel

    init(
        session: RobotSession,
        dismiss: @escaping () -> Void,
        presence: PresenceModel? = nil,
        audio: AudioSettingsModel? = nil
    ) {
        self.session = session
        self.dismiss = dismiss
        _presence = State(initialValue: presence ?? PresenceModel())
        _audio = State(initialValue: audio ?? AudioSettingsModel())
    }

    var body: some View {
        Form {
            AudioSettingsSection(session: session, model: audio)
            if session.canControlPresence {
                behaviourSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(.reachy("Presence"))
        .toolbar {
            Button(.reachy("Done"), action: dismiss)
        }
    }

    private var behaviourSection: some View {
        Section {
            Toggle(isOn: wobbling) {
                Label(.reachy("Move while speaking"), systemImage: "waveform")
            }
            Toggle(isOn: tracking) {
                Label(.reachy("Follow faces"), systemImage: "eye")
            }
            if let lastError = presence.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(.reachy("Behaviour"))
        } footer: {
            // The honest version of "we cannot read this back". Every other switch in
            // this app reflects the robot; these two reflect the request, and a
            // reader who leaves and comes back deserves to know which.
            Text(.reachy("The robot does not report these, so they show what this app last asked for."))
        }
        .disabled(presence.busy)
    }

    /// Bindings rather than `$presence.x`: each setter is a call that can be refused,
    /// and the model writes the flag only once the robot has accepted it.
    private var wobbling: Binding<Bool> {
        Binding(
            get: { presence.isWobbling },
            set: { value in Task { await presence.setWobbling(value, session: session) } }
        )
    }

    private var tracking: Binding<Bool> {
        Binding(
            get: { presence.isTracking },
            set: { value in Task { await presence.setFaceTracking(value, session: session) } }
        )
    }
}
