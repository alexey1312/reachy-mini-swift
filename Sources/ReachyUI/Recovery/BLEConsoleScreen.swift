import ReachyDesign
import ReachyKit
import SwiftUI

/// The way back in when the network is not an option: a Bluetooth link to the robot, its
/// journal, and the scripts that undo whatever took it off the air.
struct BLEConsoleScreen: View {
    @State private var model: BLEConsoleModel
    @State private var showsCommands = false
    @Environment(\.reachyPreviewMode) private var previewMode

    @MainActor
    init(model: BLEConsoleModel? = nil) {
        _model = State(initialValue: model ?? BLEConsoleModel())
    }

    var body: some View {
        Group {
            switch model.stage {
            case .scanning, .connecting:
                linkSetup
            case .locked, .unlocked:
                journal
            }
        }
        .navigationTitle(.reachy("Recovery"))
        .onAppear {
            guard !previewMode else { return }
            model.startScan()
        }
        .onDisappear {
            guard !previewMode else { return }
            model.stop()
        }
    }

    // MARK: - Getting a link

    private var linkSetup: some View {
        Form {
            Section {
                switch model.availability {
                case .ready, .unknown:
                    if model.discovered.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(.reachy("Searching over Bluetooth…")).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.discovered) { robot in
                        Button {
                            Task { await model.connect(to: robot.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                LabeledContent(robot.name) {
                                    Text(.reachy("\(robot.rssi) dBm")).font(.caption.monospaced())
                                }
                                advertisementCaption(for: robot)
                            }
                        }
                        .disabled(model.isBusy)
                    }
                case .poweredOff:
                    Label(.reachy("Bluetooth is switched off"), systemImage: "antenna.radiowaves.left.and.right.slash")
                case .unauthorized:
                    Label(.reachy("This app can't use Bluetooth"), systemImage: "hand.raised")
                    // Its onboarding twin has always offered this; here the label sat
                    // alone, on the one screen reached *because* something is already
                    // broken.
                    PrivacySettingsButton(pane: .bluetooth)
                case .unsupported:
                    Label(
                        .reachy("This device has no Bluetooth"),
                        systemImage: "antenna.radiowaves.left.and.right.slash"
                    )
                }
            } header: {
                Text(.reachy("Robot"))
            } footer: {
                Text(.reachy("Robots all advertise the same name, so they are listed by signal strength."))
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Linked

    private var journal: some View {
        // Deliberately no `failure:`. That replaces the list, and here the lines already
        // collected are the whole point — a feed that dies after six lines should leave
        // those six on screen, not swap them for an error.
        LogConsoleView(
            model: model.log,
            source: model.hardwareID ?? "bluetooth",
            emptyDescription: String(
                localized: .reachy(
                    "The robot only logs when something happens. A quiet robot sends nothing, and this stays empty."
                )
            )
        )
        .safeAreaInset(edge: .top) { notices }
        .toolbar {
            ToolbarItem {
                Button {
                    showsCommands = true
                } label: {
                    Label(.reachy("Commands"), systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .sheet(isPresented: $showsCommands) {
            NavigationStack {
                BLERecoveryCommandsSheet(model: model)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(.reachy("Done")) { showsCommands = false }
                        }
                    }
            }
            .reachySheet()
        }
    }

    /// What the robot said about itself before anything connected.
    ///
    /// **This row is how the question gets answered at all.** Every Reachy Mini
    /// advertises the same local name, so nothing in a scan tells two apart —
    /// upstream's PR #1086 puts an address and an id prefix in `ManufacturerData`,
    /// and no robot in this project has been observed sending it. Decoded when it
    /// matches that shape, printed as hex when it does not, and absent when there is
    /// nothing at all, which is what older firmware looks like.
    @ViewBuilder
    private func advertisementCaption(for robot: BLEPeripheralSnapshot) -> some View {
        if let advert = robot.advertisement {
            Text(verbatim: "\(advert.address) · \(advert.hardwareIDPrefix)…")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        } else if let raw = robot.manufacturerData {
            Text(verbatim: raw.map { String(format: "%02x", $0) }.joined())
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Not a footnote. The robot slices its buffer well past what one Bluetooth
            // read can carry and throws away what it handed over, so lines genuinely
            // disappear here and nowhere else.
            Label(
                .reachy(
                    // swiftlint:disable:next line_length
                    "Bluetooth drops journal lines when the robot logs faster than this can read. Once the robot is on the network, the Diagnostics console is the complete one."
                ),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            if model.journalFailure != nil {
                Divider()
                journalStopped
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .reachyScrim(ignoringSafeArea: .top)
    }

    /// The robot's own `journalctl` exited. Nothing on this side can prevent it, and the
    /// text it answers with (`Journal not running`) means nothing to anyone who has not
    /// read the daemon — so say what happened and offer the one thing that helps.
    private var journalStopped: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(.reachy("The robot stopped sending its log."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(.reachy("Start again")) {
                model.restartJournal()
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }
}
