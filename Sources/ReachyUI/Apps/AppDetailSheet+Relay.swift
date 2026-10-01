import ReachyDesign
import SwiftUI

/// What this page draws differently over the relay, where the robot installs by
/// name, reports nothing until the end, and keeps the rest of its store on its own
/// network.
extension AppDetailSheet {
    /// The job's log as it arrives — or, over the relay, the reason there is none.
    /// A console waiting for lines there would wait for ever: `apps.install`
    /// answers once, at the end, so the wait is named instead, with how long it
    /// may be.
    @ViewBuilder
    var progressLog: some View {
        if install.streamsLog {
            LogConsoleView(
                model: install.log,
                source: app.title,
                // The socket only wakes on a new line, so silence here is normal
                // rather than a stall — `AppJobMonitor` is polling regardless.
                emptyDescription: String(localized: .reachy("Waiting for the robot to report progress…"))
            )
            .frame(minHeight: 160)
        } else {
            Text(.reachy(
                // swiftlint:disable:next line_length
                "Over Hugging Face the robot reports only the end of an install, not its progress. A first install can take a few minutes."
            ))
            .font(Typography.status)
            .foregroundStyle(.secondary)
        }
    }

    /// Where Update, Start on wake-up and Remove would be, and the reason they are
    /// not: all three are HTTP, and the relay carries none of them.
    var lanOnlyNote: some View {
        Text(.reachy("Updating or removing this app, and starting it on wake-up, need the robot's own network."))
            .font(Typography.status)
            .foregroundStyle(.secondary)
    }
}
