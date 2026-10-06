import ReachyDesign
import ReachyKit
import SwiftUI

/// The robot's microphones, judged by the robot rather than by this device.
///
/// Its array reports `speech_detected` beside the direction of arrival, on the same
/// snapshot the twin reads, so the check is the robot itself saying it heard a voice.
/// A robot that reports no direction at all — no array, or firmware below 2.1.0 —
/// says so and lets the owner on.
struct FirstRunMicrophoneStep: View {
    let model: FirstRunModel

    @Environment(\.reachyPreviewMode) private var previewMode

    var body: some View {
        OnboardingStepScaffold(
            title: String(localized: .reachy("Say hello")),
            message: String(
                localized: .reachy("Speak near your robot. Its microphones tell this screen when they hear a voice.")
            )
        ) {
            Section {
                switch model.hearing {
                case .listening:
                    HStack(spacing: Space.sm) {
                        ProgressView()
                        Text(.reachy("Listening…"))
                            .foregroundStyle(.secondary)
                    }
                case .heard:
                    Label(.reachy("Your robot heard you"), systemImage: "checkmark.circle")
                        .foregroundStyle(Tone.success.style)
                case .unsupported:
                    Label(
                        .reachy("This robot cannot report what it hears, so there is nothing to check."),
                        systemImage: "info.circle"
                    )
                }
            } footer: {
                if model.hearing == .unsupported {
                    Text(.reachy("Its microphone array needs firmware 2.1.0 or later to report a voice."))
                }
            }
        } actions: {
            if model.hearing == .listening {
                FirstRunSkipButton(model: model)
            } else {
                ReachyActionButton(.reachy("Continue"), fullWidth: true) {
                    model.advance()
                }
            }
        }
        .task {
            guard !previewMode else { return }
            await model.listen()
        }
    }
}

/// The robot's speaker: the daemon's own test sound — over the relay through
/// `play_sound`, which is all the LAN route calls — and the level beside it.
struct FirstRunSpeakerStep: View {
    let model: FirstRunModel

    @Environment(\.reachyPreviewMode) private var previewMode

    var body: some View {
        @Bindable var audio = model.audio
        OnboardingStepScaffold(
            title: String(localized: .reachy("Hear its voice")),
            message: String(localized: .reachy("Play a sound on your robot and set a volume that suits the room."))
        ) {
            Section {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack {
                        Label(.reachy("Volume"), systemImage: "speaker.wave.2")
                        Spacer()
                        Text(.reachy("\(Int(audio.speakerPercent.rounded()))%"))
                            .font(Typography.consoleLine)
                            .foregroundStyle(.secondary)
                    }
                    // Written once a gesture ends, never on each change — the model's
                    // rule, and the reason it is shared with Settings.
                    Slider(value: $audio.speakerPercent, in: 0 ... 100, step: 1) { editing in
                        guard !editing else { return }
                        Task { await audio.commitSpeaker(session: model.session) }
                    }
                    .accessibilityLabel(Text(.reachy("Volume")))
                }
                .disabled(audio.speaker == nil)
            } footer: {
                if model.needsHelp {
                    Text(
                        .reachy(
                            // swiftlint:disable:next line_length
                            "Below about half volume the robot is hard to hear. Turn it up and play the sound again."
                        )
                    )
                }
            }
            if let message = audio.errorMessage {
                Section {
                    ReachyErrorRow(message)
                }
            }
        } actions: {
            if model.hasPlayedSound {
                ReachyActionButton(.reachy("I heard it"), fullWidth: true) {
                    model.advance()
                }
                ReachyActionButton(.reachy("Play again"), emphasis: .standard, fullWidth: true) {
                    Task { await model.playTestSound() }
                }
                .disabled(audio.isBusy)
                ReachyActionButton(.reachy("I didn't hear it"), emphasis: .quiet, fullWidth: true) {
                    model.showHelp()
                }
            } else {
                ReachyActionButton(.reachy("Play a sound"), fullWidth: true) {
                    Task { await model.playTestSound() }
                }
                .disabled(audio.isBusy)
                FirstRunSkipButton(model: model)
            }
        }
        .task {
            guard !previewMode else { return }
            await audio.load(session: model.session)
        }
    }
}
