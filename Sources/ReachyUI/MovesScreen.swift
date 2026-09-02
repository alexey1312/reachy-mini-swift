import ReachyDesign
import ReachyKit
import SwiftUI

/// Recorded moves from the Pollen HF libraries: pick a library, tap to play.
struct MovesScreen: View {
    let session: RobotSession

    /// Not used here: forwarded to `SoundboardScreen`, for the reason `MovesTab`'s
    /// copy explains.
    let presence: PresenceModel

    @State private var model: MovesModel
    @State private var recorder: MoveRecorderModel
    @Environment(\.reachyPreviewMode) private var previewMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: RobotSession,
        presence: PresenceModel,
        model: MovesModel? = nil,
        recorder: MoveRecorderModel? = nil
    ) {
        self.session = session
        self.presence = presence
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
                // The Apps tab's spelling: a segmented control drawn on the page
                // rather than inside a grouped row, which framed it in a card of
                // its own above the list it filters.
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }
            if !model.isContentLoading {
                Section {
                    if model.moves.isEmpty {
                        ContentUnavailableView(.reachy("No moves"), systemImage: "figure.dance")
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(model.moves, id: \.self) { move in
                            moveRow(move)
                        }
                    }
                }
            }
            if let lastError = model.lastError, !model.isContentLoading {
                Section {
                    ReachyErrorRow(lastError) {
                        Task { await model.load(session: session, refresh: true) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .readablePage()
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
        .toolbar { soundboardLink }
        .refreshable { await model.load(session: session, refresh: true) }
        .reachyRefreshToolbar(isDisabled: model.loading || model.isContentLoading) {
            await model.load(session: session, refresh: true)
        }
        .task(id: model.selection) {
            guard !previewMode else { return }
            await model.load(session: session)
        }
    }

    /// The glyph is decorative and says so: the row's *value* is what reads
    /// "Playing", where a glyph read out as "waveform" says nothing.
    private func moveRow(_ move: String) -> some View {
        let isPlaying = session.currentMove?.move == move
        return Button {
            Task { await model.play(move, session: session) }
        } label: {
            HStack {
                Text(MovesModel.displayName(move))
                Spacer()
                if isPlaying {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "play.circle")
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(!model.rowsAreEnabled(session))
        .accessibilityValue(isPlaying ? String(localized: .reachy("Playing")) : "")
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
                                .font(Typography.consoleLine)
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

    /// The soundboard, as a sibling of the dances rather than a sixth tab — and in
    /// the bar rather than as the first row, where it read as the first move.
    ///
    /// Gated on the capability rather than left to fail: a relayed session carries no
    /// `/api/media/*` at all, so the screen behind this item could only report that
    /// it cannot ask. The model is built inside the destination closure, which is
    /// safe for the reason `filesLink` is — a pushed screen adopts it into `@State`,
    /// and `State(initialValue:)` keeps the first one when the closure re-runs.
    @ToolbarContentBuilder
    private var soundboardLink: some ToolbarContent {
        if session.canManageSounds {
            ToolbarItem {
                NavigationLink {
                    SoundboardScreen(session: session, presence: presence)
                } label: {
                    Label(.reachy("Sounds"), systemImage: "music.note.list")
                }
                .help(Text(.reachy("Sounds")))
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
