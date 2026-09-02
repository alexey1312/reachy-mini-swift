import ReachyDesign
import ReachyKit
import SwiftUI

/// Robot speaker and microphone levels, as a `Form` section.
struct AudioSettingsSection: View {
    let session: RobotSession
    /// Dropped when the host already says "Audio" — a sheet titles itself.
    let header: String?

    @State private var model: AudioSettingsModel
    @Environment(\.reachyPreviewMode) private var previewMode

    init(session: RobotSession, header: String? = "Audio", model: AudioSettingsModel = AudioSettingsModel()) {
        self.session = session
        self.header = header
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        Section {
            if model.isLoading, !model.isReady {
                ProgressView()
            } else {
                level(
                    "Speaker",
                    systemImage: "speaker.wave.2",
                    value: $model.speakerPercent,
                    device: model.speaker
                ) {
                    await model.commitSpeaker(session: session)
                }
                level(
                    "Microphone",
                    systemImage: "mic",
                    value: $model.microphonePercent,
                    device: model.microphone
                ) {
                    await model.commitMicrophone(session: session)
                }
                if model.canTuneProfile {
                    profilePicker
                }
                Button(.reachy("Test sound")) {
                    Task { await model.playTestSound(session: session) }
                }
                .disabled(model.isBusy || !model.isReady)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
            }
        } header: {
            if let header {
                Text(header)
            }
        }
        .task {
            guard !previewMode else { return }
            await model.load(session: session)
        }
    }

    /// The audio board's profile, named by the room rather than by its registers.
    ///
    /// "Custom" appears only for a board that matches no profile, and it cannot be
    /// selected: it is a state to report, and choosing it would have nothing to write.
    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Picker(selection: profileSelection) {
                ForEach(MicrophoneProfile.allCases) { profile in
                    Text(MicrophoneProfileCaption.title(for: profile)).tag(Optional(profile))
                }
                if model.profile == nil {
                    Text(MicrophoneProfileCaption.custom).tag(MicrophoneProfile?.none)
                }
            } label: {
                Label(.reachy("Hearing"), systemImage: "waveform")
            }
            Text(model.profile.map(MicrophoneProfileCaption.detail) ?? MicrophoneProfileCaption.customDetail)
                .font(Typography.statusCompact)
                .foregroundStyle(.tertiary)
        }
        .disabled(model.isBusy)
    }

    /// Writes on selection rather than on a gesture ending, unlike the level sliders:
    /// a profile is one discrete choice, and it beeps at nobody.
    private var profileSelection: Binding<MicrophoneProfile?> {
        Binding(
            get: { model.profile },
            set: { selected in
                guard let selected, selected != model.profile else { return }
                Task { await model.applyProfile(selected, session: session) }
            }
        )
    }

    private func level(
        _ title: String,
        systemImage: String,
        value: Binding<Double>,
        device: AudioLevel?,
        commit: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(.reachy("\(Int(value.wrappedValue.rounded()))%"))
                    .font(Typography.consoleLine)
                    .foregroundStyle(.secondary)
            }
            // The daemon reaches the robot's audio through one named sink or
            // source; a robot with several gives no other hint which one moved.
            // The name goes on as an accessibility label rather than through `label:`:
            // on iOS 26 the labelled initialiser draws a tick per step, and a hundred
            // ticks under a volume track is not a slider anybody asked for.
            Slider(value: value, in: 0 ... 100, step: 1) { editing in
                guard !editing else { return }
                Task { await commit() }
            }
            .accessibilityLabel(Text(title))
            // Only the LAN routes name the device; a remote session reports the
            // level alone, and a line reading " · " would be worse than none.
            if let name = device?.device, let platform = device?.platform {
                Text(.reachy("\(name) · \(platform)"))
                    .font(Typography.statusCompact)
                    .foregroundStyle(.tertiary)
            }
        }
        .disabled(device == nil)
    }
}
