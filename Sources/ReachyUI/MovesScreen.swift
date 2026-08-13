import ReachyDesign
import ReachyKit
import SwiftUI

/// Recorded moves from the Pollen HF libraries: pick a library, tap to play.
struct MovesScreen: View {
    let session: RobotSession

    @State private var model: MovesModel
    @State private var recorder: MoveRecorderModel
    @Environment(\.reachyPreviewMode) private var previewMode

    init(session: RobotSession, model: MovesModel? = nil, recorder: MoveRecorderModel? = nil) {
        self.session = session
        // Not a default argument: it has to be built *from* `session` so the
        // libraries the disk cache warmed are on the first frame.
        _model = State(initialValue: model ?? MovesModel(session: session))
        _recorder = State(initialValue: recorder ?? MoveRecorderModel())
    }

    var body: some View {
        @Bindable var model = model
        Form {
            if !session.isAwake {
                Section {
                    AsleepBanner(session: session)
                }
            }
            recordingsSection
            Section {
                Picker(.reachy("Library"), selection: $model.selection) {
                    ForEach(MovesModel.libraries.indices, id: \.self) { index in
                        Text(MovesModel.libraries[index].title).tag(index)
                    }
                }
                .pickerStyle(.segmented)
            }
            if !model.isContentLoading {
                Section {
                    if model.moves.isEmpty {
                        Text(.reachy("No moves")).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.moves, id: \.self) { move in
                            Button {
                                Task { await model.play(move, session: session) }
                            } label: {
                                HStack {
                                    Text(MovesModel.displayName(move))
                                    Spacer()
                                    if session.currentMove?.move == move {
                                        Image(systemName: "waveform")
                                            .symbolEffect(.variableColor.iterative)
                                    } else {
                                        Image(systemName: "play.circle")
                                    }
                                }
                            }
                            .disabled(!model.rowsAreEnabled(session))
                        }
                    }
                }
            }
            if let lastError = model.lastError, !model.isContentLoading {
                Section {
                    Text(lastError)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .contentLoading(
            isPresented: model.isContentLoading,
            title: model.selectedLibrary.loadingTitle
        )
        .navigationTitle(.reachy("Moves"))
        .safeAreaInset(edge: .bottom) {
            if let activity = session.moveActivity {
                MoveActivityBar(activity: activity) {
                    Task { await model.stop(session: session) }
                }
            }
        }
        .toolbar {
            Button {
                Task { await model.load(session: session, refresh: true) }
            } label: {
                Label(.reachy("Refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(model.loading || model.isContentLoading)
        }
        .task(id: model.selection) {
            guard !previewMode else { return }
            await model.load(session: session)
        }
    }

    /// Takes this phone made, above the robot's own libraries.
    ///
    /// Above, because these are the reader's: the Pollen libraries are hundreds of
    /// dances behind a picker, and a section that only exists once you have recorded
    /// something is not competing with them for the top of a cold screen.
    @ViewBuilder
    private var recordingsSection: some View {
        if !recorder.recordings.isEmpty {
            Section {
                ForEach(recorder.recordings) { recording in
                    Button {
                        play(recording)
                    } label: {
                        LabeledContent(recording.name) {
                            Text(.reachy("\(Self.seconds(recording.duration)) s"))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!canPlayRecording)
                }
                .onDelete { offsets in
                    for index in offsets {
                        recorder.delete(recorder.recordings[index].id)
                    }
                }
            } header: {
                Text(.reachy("Your recordings"))
            }
        }
    }

    /// A recording is teleop rather than a daemon move, so it needs the same
    /// capability the joystick does — and the same awake robot, since disabled motors
    /// swallow every target without reporting anything.
    private var canPlayRecording: Bool {
        session.canTeleoperate && session.isAwake && !recorder.isPlaying
    }

    /// Frees the daemon's one move slot first: a dance already playing would fight
    /// the targets this is about to send, and `play_move` drops the loser in silence.
    private func play(_ recording: MoveRecording) {
        Task {
            if session.moveActivity != nil {
                await model.stop(session: session)
            }
            guard let channel = try? session.makeTeleop() else { return }
            await recorder.play(recording, channel: channel)
        }
    }

    private static func seconds(_ duration: TimeInterval) -> String {
        duration.formatted(.number.precision(.fractionLength(1)))
    }
}
