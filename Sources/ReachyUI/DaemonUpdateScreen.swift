import ReachyDesign
import ReachyKit
import SwiftUI

/// Shown when the handshake found a robot whose daemon is below the supported
/// baseline. Retrying was never going to help, so this offers the one thing that
/// can: the daemon's own update route.
struct DaemonUpdateScreen: View {
    let session: RobotSession
    let requirement: DaemonUpdateRequirement

    @State private var model: SystemUpdateModel?
    @AppStorage("update.preRelease") private var preRelease = false
    @State private var showsLog = false

    /// An injected model is also what keeps the `.task` below inert — it only builds and
    /// checks when there is none, so a preview never reaches the network.
    @MainActor
    init(session: RobotSession, requirement: DaemonUpdateRequirement, model: SystemUpdateModel? = nil) {
        self.session = session
        self.requirement = requirement
        _model = State(initialValue: model)
    }

    private var state: SystemUpdateModel.State {
        model?.state ?? .idle
    }

    var body: some View {
        Form {
            Section {
                Label(.reachy("This robot needs a software update"), systemImage: "arrow.down.circle")
                    .font(Typography.rowTitle)
                LabeledContent(.reachy("Robot runs"), value: requirement.reported)
                LabeledContent(.reachy("This app needs"), value: requirement.minimum)
            } footer: {
                Text(
                    requirement.canSelfUpdate
                        ? String(
                            localized: .reachy(
                                // swiftlint:disable:next line_length
                                "The robot downloads the update itself, so it needs internet access. It restarts when the update finishes."
                            )
                        )
                        : String(
                            localized: .reachy(
                                // swiftlint:disable:next line_length
                                "This robot cannot update itself over the network. Connect it to the official desktop app over USB to update it."
                            )
                        )
                )
            }

            if requirement.canSelfUpdate {
                Section(.reachy("Update")) {
                    statusRow
                    actions
                }
            }

            Section {
                Button(.reachy("Disconnect"), role: .destructive) { session.disconnect() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(.reachy("Robot update"))
        .task {
            guard model == nil else { return }
            let model = SystemUpdateModel(session: session)
            self.model = model
            if requirement.canSelfUpdate {
                await model.check(preRelease: preRelease)
            }
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

    /// `.upToDate` is reachable here, and it is the state this screen phrases
    /// differently from the settings card: the robot is on the newest published
    /// release and that release is still older than this app needs.
    private var statusRow: some View {
        SystemUpdateStatusRow(row: SystemUpdateCaption.row(for: state, purpose: .required))
    }

    @ViewBuilder
    private var actions: some View {
        Toggle(.reachy("Include pre-release versions"), isOn: $preRelease)
            .disabled(model?.isBusy ?? true)
            .onChange(of: preRelease) { _, newValue in
                Task { await model?.check(preRelease: newValue) }
            }

        if case .available = state {
            // The one thing this screen exists for, drawn as the answer to the
            // question above it rather than as one more blue row.
            ReachyActionButton(.reachy("Update now"), fullWidth: true) {
                Task { await model?.install(preRelease: preRelease) }
            }
        } else if case .finished = state {
            if let address = session.address {
                Button(.reachy("Connect now")) {
                    Task { await session.connect(to: address) }
                }
            }
        } else if !(model?.isBusy ?? true) {
            Button(.reachy("Check again")) {
                Task { await model?.check(preRelease: preRelease) }
            }
        }

        if model?.log.entries.isEmpty == false {
            Button(.reachy("Show installer log")) { showsLog = true }
        }
    }
}
