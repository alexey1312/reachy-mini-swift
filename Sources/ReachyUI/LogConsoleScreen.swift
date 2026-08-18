import ReachyDesign
import ReachyKit
import SwiftUI

/// Live daemon log console (journalctl tail over WebSocket).
struct LogConsoleScreen: View {
    let session: RobotSession

    @State private var model: LogConsoleModel
    @State private var setupError: String?
    @Environment(\.reachyPreviewMode) private var previewMode

    init(session: RobotSession, model: LogConsoleModel = LogConsoleModel(), setupError: String? = nil) {
        self.session = session
        _model = State(initialValue: model)
        _setupError = State(initialValue: setupError)
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
