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
    /// Absent in previews and wherever no camera is up: without one there is no track
    /// to scale, and a slider over nothing is worse than no slider.
    var viewport: ViewportModel?

    @State private var presence: PresenceModel
    @State private var audio: AudioSettingsModel

    init(
        session: RobotSession,
        dismiss: @escaping () -> Void,
        viewport: ViewportModel? = nil,
        presence: PresenceModel? = nil,
        audio: AudioSettingsModel? = nil
    ) {
        self.session = session
        self.dismiss = dismiss
        self.viewport = viewport
        _presence = State(initialValue: presence ?? PresenceModel())
        _audio = State(initialValue: audio ?? AudioSettingsModel())
    }

    var body: some View {
        Form {
            AudioSettingsSection(session: session, model: audio)
            if let viewport {
                voiceSection(viewport)
            }
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

    /// How loud this device's voice is when the robot plays it.
    ///
    /// It belongs beside the robot's own levels and is not one of them: the robot's
    /// speaker slider moves everything the robot plays, and this moves one source.
    /// It is here because the robot has no headroom left — the daemon adds no gain
    /// and its mixer is already at the top, so a call that drowns out the robot's own
    /// sounds can only be brought down, never matched.
    private func voiceSection(_ viewport: ViewportModel) -> some View {
        @Bindable var viewport = viewport
        return Section {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack {
                    Label(.reachy("Your voice"), systemImage: "person.wave.2")
                    Spacer()
                    Text(.reachy("\(Int((viewport.callMicVolume * 100).rounded()))%"))
                        .font(Typography.consoleLine)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $viewport.callMicVolume, in: ViewportModel.micVolumeRange, step: 0.05)
                Text(.reachy("How loud you are when the robot plays your voice. It takes effect at once."))
                    .font(Typography.statusCompact)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            Text(.reachy("Call"))
        }
    }

    private var behaviourSection: some View {
        Section {
            MoveWhileSpeakingToggle(session: session, presence: presence)
            Toggle(isOn: tracking) {
                Label(.reachy("Follow faces"), systemImage: "eye")
            }
            if presence.isTracking {
                followStrength
                faceReading
            }
            if let lastError = presence.lastError {
                Text(lastError)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
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

    /// The one honest reading in this section, so it claims only what it knows:
    /// whether the robot has somebody to follow. It says nothing about the switch
    /// above — a tracker that sees nobody looks exactly like one that is off — and
    /// it is silent before the first answer and after a failed poll.
    @ViewBuilder
    private var faceReading: some View {
        switch presence.seesFace {
        case true:
            Label(.reachy("Following someone"), systemImage: "eye.fill")
                .font(Typography.status)
                .foregroundStyle(Tone.success.style)
        case false:
            Label(.reachy("No one in view"), systemImage: "eye.slash")
                .font(Typography.status)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    /// Only under a switch that is on, because the daemon takes the weight as a
    /// parameter of *enabling* — there is no route that sets it alone, so a slider over
    /// an off switch would be a control with nothing to send.
    ///
    /// The robot hears it once the thumb lifts, the way the two audio levels are sent:
    /// dragging across the range would otherwise re-enable tracking at every step.
    private var followStrength: some View {
        @Bindable var presence = presence
        return VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Text(.reachy("Follow strength"))
                Spacer()
                Text(.reachy("\(Int((presence.trackingWeight * 100).rounded()))%"))
                    .font(Typography.consoleLine)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $presence.trackingWeight, in: PresenceModel.weightRange, step: 0.05) { editing in
                guard !editing else { return }
                Task { await presence.commitTrackingWeight(session: session) }
            }
            Text(.reachy("Lower means the head follows less of the way. The switch above is what stops it."))
                .font(Typography.statusCompact)
                .foregroundStyle(.tertiary)
        }
    }

    /// A binding rather than `$presence.isTracking`: the setter is a call that can be
    /// refused, and the model writes the flag only once the robot has accepted it.
    private var tracking: Binding<Bool> {
        Binding(
            get: { presence.isTracking },
            set: { value in Task { await presence.setFaceTracking(value, session: session) } }
        )
    }
}
