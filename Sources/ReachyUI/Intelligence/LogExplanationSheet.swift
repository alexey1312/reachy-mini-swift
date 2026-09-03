import ReachyDesign
import SwiftUI

/// What the on-device model made of the log that is on screen.
///
/// A sheet rather than a panel inside the console, and that is a layout fact rather
/// than a preference: the console is a full-bleed `List` that already owns a bottom
/// `safeAreaInset` and a search field, so an inline panel would push the tail around
/// on the one screen where the tail moving is the whole point.
///
/// The caller supplies the `NavigationStack` and `.reachySheet()`, the shape
/// `SystemUpdateCard` and `AppDetailSheet` already use.
struct LogExplanationSheet: View {
    let model: LogExplanationModel
    /// Frozen at presentation. The corpus must not change under the reader while the
    /// model is generating.
    let entries: [LogEntry]
    let filterSummary: String?
    let dismiss: () -> Void

    @Environment(\.reachyPreviewMode) private var previewMode

    var body: some View {
        Form {
            content
        }
        // `.grouped` explicitly: macOS defaults to `.columns`, which clips inside a
        // sheet — the lesson `HFSignInScreen` already carries.
        .formStyle(.grouped)
        .navigationTitle(.reachy("Explain the log"))
        .contentLoading(isPresented: model.isBusy, title: .reachy("Reading the log…"))
        .toolbar { toolbar }
        .task { await start() }
    }

    /// Opening the sheet *is* the request — a second tap would be ceremony. The
    /// `.task` also cancels on dismissal, which is what makes a cancelled run silent
    /// rather than a failure.
    ///
    /// **The preview guard is load-bearing and was found in a reference.** An injected
    /// model is already in its end state, and running this over it replaced a seeded
    /// summary with the stub's empty one — the same trap `LogConsoleScreen.stream()`
    /// and `PermissionsScreen.appeared()` already carry this guard for.
    private func start() async {
        guard !previewMode else { return }
        await model.explain(entries, filterSummary: filterSummary)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case let .explained(explanation):
            Section {
                Text(explanation.text)
                    .font(Typography.detail)
                    .textSelection(.enabled)
            }
            Section {
                disclosure(explanation)
            }
        case let .failed(message):
            Section {
                ContentUnavailableView(
                    .reachy("Couldn't explain the log"),
                    systemImage: "sparkles.slash",
                    description: Text(message)
                )
                Button(.reachy("Try again")) {
                    Task { await start() }
                }
            }
        // `.explaining` draws nothing: `contentLoading` covers the form. `.idle` and
        // `.unavailable` are unreachable here — the sheet only opens from a button
        // that only exists when the model is offered — but the switch must be total,
        // and a `fatalError` on an unreachable UI branch is worse than an empty one.
        case .explaining, .idle, .unavailable:
            EmptyView()
        }
    }

    /// Not decoration, and not to be trimmed: it says the text was made on the device
    /// and that the log, not the summary, is the record.
    private func disclosure(_ explanation: LogExplanation) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            // swiftlint:disable:next line_length
            Text(.reachy("Summarized on this device and never sent anywhere. It can be wrong — the log is the record."))
            Text(coverage(explanation))
            if let filter = explanation.filterSummary {
                Text(filter)
            }
        }
        .font(Typography.footer)
        .foregroundStyle(Tone.quiet.style)
    }

    /// An interpolating key, so it is absent from the catalogue by design — the
    /// documented rule for keys whose placeholder types cannot be read off the call
    /// site. It reads in English until the interpolating pass, exactly as the console's
    /// own line count already does.
    private func coverage(_ explanation: LogExplanation) -> String {
        let sent = explanation.coverage.includedLines
        let total = explanation.coverage.totalLines
        return String(localized: .reachy("\(sent) of \(total) lines were sent."))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(.reachy("Done"), action: dismiss)
        }
        if case let .explained(explanation) = model.phase {
            ToolbarItem {
                Button(.reachy("Copy")) { Clipboard.copy(explanation.text) }
            }
        }
    }
}
