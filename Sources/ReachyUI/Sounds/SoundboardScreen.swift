import ReachyDesign
import ReachyKit
import SwiftUI
import UniformTypeIdentifiers

/// The robot's soundboard: tap to play, send audio from this device, delete either
/// copy.
///
/// Pushed from the Moves tab rather than given a tab of its own — the five are
/// unconditional (`AGENTS.md`), and "things the robot does when you ask" is the tab
/// this already belongs to.
struct SoundboardScreen: View {
    let session: RobotSession

    @State private var model: SoundboardModel
    @State private var isImporting = false
    @Environment(\.reachyPreviewMode) private var previewMode

    /// `nil` rather than a defaulted value, for the reason every screen here does it:
    /// a default argument is evaluated nonisolated, and this model is `@MainActor`.
    init(session: RobotSession, model: SoundboardModel? = nil) {
        self.session = session
        _model = State(initialValue: model ?? SoundboardModel())
    }

    var body: some View {
        Form {
            if !session.isBackendRunning {
                Section {
                    AsleepBanner(session: session)
                }
            }
            resendSection
            soundsSection
            if let lastError = model.lastError {
                Section {
                    Text(lastError)
                        .font(Typography.consoleLine)
                        .foregroundStyle(Tone.danger.style)
                }
            }
        }
        .formStyle(.grouped)
        .contentLoading(
            isPresented: model.isContentLoading,
            title: .reachy("Asking the robot what it can play…")
        )
        .overlay {
            if model.rows.isEmpty, !model.isContentLoading, model.lastError == nil {
                emptyState
            }
        }
        .navigationTitle(.reachy("Sounds"))
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio]) { result in
            guard case let .success(url) = result else { return }
            // The model copies the file into this device's library and sends it, off
            // the main actor, reporting a refusal through the slot every other failure
            // on this screen uses.
            Task { await model.importFile(at: url, session: session) }
        }
        .confirmationDialog(
            model.confirmationTitle,
            isPresented: confirmingBinding,
            titleVisibility: .visible
        ) {
            if let confirming = model.confirming {
                confirmationActions(for: confirming)
            }
            Button(.reachy("Cancel"), role: .cancel) { model.confirming = nil }
        } message: {
            if let confirming = model.confirming {
                Text(model.confirmationMessage(for: confirming))
            }
        }
        .task {
            guard !previewMode else { return }
            await model.load(session: session)
        }
    }

    // MARK: - Sections

    private var soundsSection: some View {
        Section {
            ForEach(model.rows) { row in
                Button {
                    Task { await model.play(row, session: session) }
                } label: {
                    SoundRow(row: row, isBusy: model.busy == row.id, wasLastPlayed: model.lastPlayed == row.id)
                }
                .disabled(!model.rowsAreEnabled(session))
                .swipeActions(edge: .trailing) { actions(for: row) }
                .contextMenu { actions(for: row) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(.reachy("The robot keeps these in temporary storage and forgets them when it restarts."))
                Text(.reachy("“Move while speaking” in the live view makes the head move to whatever is playing."))
            }
        }
    }

    /// Only above sounds the robot is missing, which after a restart is all of them.
    @ViewBuilder
    private var resendSection: some View {
        if !model.missingFromRobot.isEmpty, session.canManageSounds {
            Section {
                Button {
                    Task { await model.sendMissing(session: session) }
                } label: {
                    Label(
                        .reachy("Send \(model.missingFromRobot.count) to the robot"),
                        systemImage: "arrow.up.circle"
                    )
                }
                .disabled(model.busy != nil)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(.reachy("No sounds"), systemImage: "music.note.list")
        } description: {
            Text(.reachy("Send an audio file from this device and the robot can play it on demand."))
        } actions: {
            Button(.reachy("Add a sound")) { isImporting = true }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await model.load(session: session) }
            } label: {
                Label(.reachy("Refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(model.loading || model.busy != nil)
        }
        ToolbarItem {
            // Always available, and deliberately not conditional on anything: no route
            // reports whether a sound is playing, so a Stop that came and went would be
            // guessing. Sending it over silence is free.
            Button {
                Task { await model.stop(session: session) }
            } label: {
                Label(.reachy("Stop the sound"), systemImage: "stop.circle")
            }
            .disabled(!session.canManageSounds)
        }
        ToolbarItem {
            Button {
                isImporting = true
            } label: {
                Label(.reachy("Add a sound"), systemImage: "plus")
            }
        }
    }

    // MARK: - Row actions

    /// Built once and offered as both a swipe and a context menu, so the two cannot
    /// drift — the shape `AppStoreScreen` uses for the same reason.
    @ViewBuilder
    private func actions(for row: SoundboardModel.Row) -> some View {
        if row.presence != .both, row.presence != .robotOnly {
            Button {
                Task { await model.send(row, session: session) }
            } label: {
                Label(.reachy("Send to the robot"), systemImage: "arrow.up.circle")
            }
        }
        if row.presence != .deviceOnly {
            Button(role: .destructive) {
                model.confirming = .robot(row)
            } label: {
                Label(.reachy("Delete the robot's copy"), systemImage: "trash")
            }
        }
        if row.presence != .robotOnly {
            Button(role: .destructive) {
                model.confirming = .device(row)
            } label: {
                Label(.reachy("Remove from this device"), systemImage: "iphone.slash")
            }
        }
    }

    // MARK: - Confirmation

    private var confirmingBinding: Binding<Bool> {
        Binding(get: { model.confirming != nil }, set: { presented in
            if !presented {
                model.confirming = nil
            }
        })
    }

    /// The buttons. The wording of the title and the message lives on the model, because a
    /// `confirmationDialog` captures as nothing and that copy would otherwise be covered
    /// by neither a reference nor a test.
    @ViewBuilder
    private func confirmationActions(for target: SoundboardModel.Confirmation) -> some View {
        switch target {
        case let .robot(row):
            Button(.reachy("Delete"), role: .destructive) {
                model.confirming = nil
                Task { await model.deleteFromRobot(row, session: session) }
            }
        case let .device(row):
            Button(.reachy("Forget"), role: .destructive) {
                model.confirming = nil
                Task { await model.removeFromDevice(row) }
            }
        }
    }
}

/// One sound, and where it is.
private struct SoundRow: View {
    let row: SoundboardModel.Row
    let isBusy: Bool
    let wasLastPlayed: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(row.sound.displayName)
                    .font(Typography.rowTitleCompact)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(Typography.status)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            // A static glyph rather than a `ProgressView`: an indeterminate spinner is
            // captured at whatever phase the run reached, which is what makes a
            // reference image move for no reason belonging to the change.
            Image(systemName: isBusy ? "arrow.up.circle" : "play.circle")
                .foregroundStyle(isBusy ? Tone.quiet.style : AnyShapeStyle(.tint))
        }
    }

    /// **Nothing here claims a sound is playing**, and `unknown` says nothing about the
    /// robot at all: a listing that failed is not evidence the robot is missing
    /// anything.
    private var caption: LocalizedStringResource? {
        switch row.presence {
        case .deviceOnly: .reachy("Not on the robot yet")
        case .robotOnly: .reachy("On the robot only — not saved here")
        case .both, .unknown: wasLastPlayed ? .reachy("Last played") : nil
        }
    }
}
