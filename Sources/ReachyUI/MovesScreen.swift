import ReachyDesign
import ReachyKit
import SwiftUI

/// Recorded moves from the Pollen HF libraries: pick a library, tap to play.
struct MovesScreen: View {
    let session: RobotSession

    @State private var model: MovesModel
    @Environment(\.reachyPreviewMode) private var previewMode

    init(session: RobotSession, model: MovesModel? = nil) {
        self.session = session
        // Not a default argument: it has to be built *from* `session` so the
        // libraries the disk cache warmed are on the first frame.
        _model = State(initialValue: model ?? MovesModel(session: session))
    }

    var body: some View {
        @Bindable var model = model
        Form {
            if !session.isAwake {
                Section {
                    AsleepBanner(session: session)
                }
            }
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
}
