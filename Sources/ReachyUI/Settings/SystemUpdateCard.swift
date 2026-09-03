import ReachyDesign
import ReachyKit
import SwiftUI

/// Robot software updates from settings, as opposed to the blocking
/// `DaemonUpdateScreen` a too-old daemon lands on. Same model, same log.
struct SystemUpdateCard: View {
    let session: RobotSession

    @State private var model: SystemUpdateModel?
    @AppStorage("update.preRelease") private var preRelease = false
    @State private var showsLog = false

    /// An injected model is also what keeps the `.task` below inert — it only builds one
    /// when there is none, so a preview never reaches the network.
    @MainActor
    init(session: RobotSession, model: SystemUpdateModel? = nil) {
        self.session = session
        _model = State(initialValue: model)
    }

    var body: some View {
        Section {
            statusRow
            Toggle(.reachy("Include pre-release versions"), isOn: $preRelease)
                .disabled((model?.isBusy ?? true) || session.refusesPreReleaseUpdates)
                .onChange(of: preRelease) { _, newValue in
                    Task { await model?.check(preRelease: newValue) }
                }
            actions
        } header: {
            Text(.reachy("System update"))
        } footer: {
            // One view, not two: given a bare pair of `Text`s the section footer
            // rendered only the first, and the warning vanished with no error
            // anywhere.
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(.reachy("The robot downloads updates itself and restarts when one finishes."))
                if session.refusesPreReleaseUpdates {
                    Text(.reachy(
                        // swiftlint:disable:next line_length
                        "Pre-release versions need daemon 1.10.0. An older robot finds the wrong version and refuses to install it."
                    ))
                }
            }
        }
        .task {
            guard model == nil else { return }
            model = SystemUpdateModel(session: session)
        }
        .sheet(isPresented: $showsLog) {
            if let model {
                NavigationStack {
                    LogConsoleView(
                        model: model.log,
                        source: session.address?.displayString ?? "robot",
                        emptyDescription: String(localized: .reachy("The robot has not sent any installer output yet."))
                    )
                    .navigationTitle(.reachy("Update log"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(.reachy("Done")) { showsLog = false }
                        }
                    }
                }
                .reachySheet()
            }
        }
    }

    private var statusRow: some View {
        SystemUpdateStatusRow(
            row: SystemUpdateCaption.row(
                for: model?.state ?? .idle,
                purpose: .offered,
                installed: session.lastStatus?.version
            )
        )
    }

    @ViewBuilder
    private var actions: some View {
        if case .available = model?.state {
            Button(.reachy("Update now")) {
                Task { await model?.install(preRelease: preRelease) }
            }
        } else if !(model?.isBusy ?? true) {
            Button(.reachy("Check for updates")) {
                Task { await model?.check(preRelease: preRelease) }
            }
        }
        if model?.log.entries.isEmpty == false {
            Button(.reachy("Show installer log")) { showsLog = true }
        }
    }
}
