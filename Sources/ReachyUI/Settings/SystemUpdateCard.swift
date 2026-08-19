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
                .disabled(model?.isBusy ?? true)
                .onChange(of: preRelease) { _, newValue in
                    Task { await model?.check(preRelease: newValue) }
                }
            actions
        } header: {
            Text(.reachy("System update"))
        } footer: {
            Text(.reachy("The robot downloads updates itself and restarts when one finishes."))
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

    @ViewBuilder
    private var statusRow: some View {
        switch model?.state ?? .idle {
        case .idle:
            LabeledContent(.reachy("Installed"), value: session.lastStatus?.version ?? "—")
        case .checking:
            Label(.reachy("Checking for updates…"), systemImage: "arrow.triangle.2.circlepath")
        case let .upToDate(current):
            Label(.reachy("Up to date — \(current)"), systemImage: "checkmark.circle")
                .foregroundStyle(Tone.success.style)
        case let .robotOffline(current):
            Label(.reachy("\(current) — the robot can't reach the internet"), systemImage: "wifi.exclamationmark")
                .foregroundStyle(Tone.warning.style)
        case let .available(current, latest):
            LabeledContent(.reachy("Update available")) { Text(.reachy("\(current) → \(latest)")).monospaced() }
        case .installing:
            Label(.reachy("Installing — this takes a minute or two…"), systemImage: "arrow.down.circle")
        case .restarting:
            Label(.reachy("The robot is restarting…"), systemImage: "arrow.clockwise")
        case let .finished(version):
            Label(.reachy("Updated to \(version)."), systemImage: "checkmark.circle")
                .foregroundStyle(Tone.success.style)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon")
                .foregroundStyle(Tone.danger.style)
        }
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
