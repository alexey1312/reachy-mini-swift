import ReachyDesign
import ReachyKit
import SwiftUI

/// Live daemon log console (journalctl tail over WebSocket).
struct LogConsoleScreen: View {
    let session: RobotSession

    @State private var model: LogConsoleModel
    @State private var setupError: String?
    /// Owned here rather than by the sheet: a model built inside a `.sheet` content
    /// closure is rebuilt every time this body re-runs, which it does on every log
    /// chunk. `nil` and resolved in the body, because a default argument is evaluated
    /// in a nonisolated context.
    @State private var explain: LogExplanationModel
    @State private var showsExplanation = false
    @Environment(\.reachyPreviewMode) private var previewMode

    init(
        session: RobotSession,
        model: LogConsoleModel = LogConsoleModel(),
        setupError: String? = nil,
        explain: LogExplanationModel? = nil
    ) {
        self.session = session
        _model = State(initialValue: model)
        _setupError = State(initialValue: setupError)
        _explain = State(initialValue: explain ?? LogExplanationModel())
    }

    var body: some View {
        LogConsoleView(
            model: model,
            source: ConnectionLinkCaption.text(for: session.link),
            emptyDescription: emptyDescription,
            failure: setupError
        )
        .navigationTitle(.reachy("Daemon logs"))
        .task { await stream() }
        // Re-read on every appearance: `.modelNotReady` becomes `.available` while the
        // assets finish downloading and nothing exists to tell the app. No preview
        // guard is needed — a preview controls the gate through the injected closure,
        // which is the seam doing its job.
        .task { explain.refresh() }
        .toolbar { explainItem }
        .sheet(isPresented: $showsExplanation) {
            NavigationStack {
                LogExplanationSheet(
                    model: explain,
                    // Frozen at presentation, and `visible` rather than `entries`:
                    // `copyText` and `export(address:)` already ship what is on
                    // screen, and a third "take what you can see" operation quietly
                    // taking something else would be the surprising one.
                    entries: model.visible,
                    filterSummary: model.filterSummary,
                    dismiss: { showsExplanation = false }
                )
            }
            .reachySheet()
        }
    }

    /// **Hidden, not disabled, when the model is unavailable** — the issue's own rule.
    /// On a device below iOS 26, on a Mac with Apple Intelligence switched off, and on
    /// ineligible hardware there is no button and no explanation of its absence.
    ///
    /// `.disabled` is the other condition entirely, and it matches what `Export` and
    /// `Copy all` already do with an empty console.
    @ToolbarContentBuilder
    private var explainItem: some ToolbarContent {
        if explain.isOffered {
            ToolbarItem {
                Button(.reachy("Explain"), systemImage: "sparkles") { showsExplanation = true }
                    .disabled(model.visible.isEmpty)
            }
        }
    }

    /// The two transports go quiet for different reasons, and naming the wrong one
    /// sends the reader looking for a problem they do not have. The LAN route needs
    /// `--wireless-version` and the simulator refuses the upgrade outright; the
    /// channel reaches every robot but still needs a journal at the other end.
    private var emptyDescription: String {
        session.isRemote
            ?
            String(
                localized: .reachy(
                    "Daemon logs come from journalctl on the robot, which a development host may not have."
                )
            )
            :
            String(
                localized: .reachy("Daemon logs come from journalctl on the robot — the local simulator has none.")
            )
    }

    /// `.task` cancels the stream when the screen goes away — no manual task handle.
    private func stream() async {
        guard !previewMode else { return }
        do {
            for await chunk in try session.daemonLogLines() {
                model.ingest(chunk)
            }
        } catch {
            setupError = RobotSession.describe(error)
        }
    }
}
