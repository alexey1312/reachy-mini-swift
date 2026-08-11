import ReachyDesign
import ReachyKit
import SwiftUI

/// Connected-robot controls: identity, live daemon status, wake/sleep, audio.
///
/// The navigation container is the host's — this is a column on iPad and Mac and
/// a tab on iPhone, and both supply their own `NavigationStack`.
struct RobotScreen: View {
    let session: RobotSession

    @State private var powerOff = RobotPowerOffModel()

    var body: some View {
        Form {
            statusSection
            controlSection
            if let warning = session.compatibilityWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if let error = session.robotError {
                Section {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button(.reachy("Disconnect"), role: .destructive) {
                    session.disconnect()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(identity?.name ?? "Robot")
    }

    private var identity: RobotIdentity? {
        switch session.phase {
        case let .connected(identity), let .unreachable(identity): identity
        default: nil
        }
    }

    private var statusSection: some View {
        Section(.reachy("Robot")) {
            LabeledContent(.reachy("Name"), value: identity?.name ?? "—")
            LabeledContent(.reachy("Daemon"), value: identity?.daemonVersion ?? "—")
            LabeledContent(.reachy("Connection"), value: session.link.displayString)
            if let status = session.lastStatus {
                LabeledContent(
                    .reachy("Daemon state"),
                    value: String(localized: DaemonStateCaption.text(for: status.state))
                )
                // A `disabled` robot answers every motion command and stays limp,
                // so the motor mode belongs next to the daemon state.
                if let mode = status.backendStatus?.value1?.motorControlMode {
                    LabeledContent(.reachy("Motors"), value: mode.rawValue)
                }
            }
            HStack {
                Text(.reachy("Link"))
                Spacer()
                if case .unreachable = session.phase {
                    Label(.reachy("Unreachable — reconnecting…"), systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                } else if !session.isBackendRunning {
                    // Reachable but not drivable: claiming a green "Connected" here
                    // is what sent users looking for a network problem they don't have.
                    Label(.reachy("Backend stopped"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Label(.reachy("Connected"), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
            if let fault = session.backendFault {
                Label(fault, systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    /// Power alone. The three destinations that used to sit above these buttons are
    /// each a tab or a settings row now — the controller behind Live, the move
    /// library at the root of its own tab, the daemon log with the rest of the
    /// diagnostics — so this screen is about the robot's identity and its state.
    ///
    /// The three rows are one ladder, in the order they take things away: waking
    /// gives the robot its motors, sleeping takes them, powering off takes the
    /// backend behind them. Only the last needs asking twice.
    private var controlSection: some View {
        Section {
            Button {
                Task { await session.wake() }
            } label: {
                Label(.reachy("Wake up"), systemImage: "sun.max")
            }
            .disabled(session.powerTransition != nil)
            Button {
                Task { await session.sleep() }
            } label: {
                Label(.reachy("Go to sleep"), systemImage: "moon.zzz")
            }
            .disabled(session.powerTransition != nil)
            Button(role: .destructive) {
                powerOff.isConfirming = true
            } label: {
                Label(.reachy("Power off"), systemImage: "power")
            }
            .disabled(!powerOff.canPowerOff(session))
            if let transition = session.powerTransition {
                PowerTransitionRow(transition: transition)
            }
        } header: {
            Text(.reachy("Control"))
        } footer: {
            Text(powerOffDescription)
        }
        .disabled(!isConnected)
        .confirmationDialog(
            Text(.reachy("Stop the robot backend?")),
            isPresented: $powerOff.isConfirming,
            titleVisibility: .visible
        ) {
            Button(.reachy("Power the robot off"), role: .destructive) {
                Task { await powerOff.perform(session) }
            }
        } message: {
            Text(powerOffConfirmation)
        }
    }

    /// Says what "off" means here, because the word covers three different things on
    /// a robot and this is only one of them: the motors, the camera and the state
    /// stream go, the daemon that answers this app does not.
    ///
    /// It names Wake up rather than Connect. The daemon's own server survives the
    /// teardown, so the session stays `.connected` and the gate — the app's only
    /// screen called Connect — is never shown again; `wake()` is what starts the
    /// backend from here, through `daemon/start?wake_up=true`.
    ///
    /// A section footer rather than a caption row, unlike `MaintenanceCard`, which
    /// puts each sentence above its button. There the sentence belongs to one of two
    /// rows that both need one; here two of the three rows need nothing, and a
    /// caption between them would read as a footnote to sleeping.
    private var powerOffDescription: LocalizedStringResource {
        if session.address == nil {
            // A relay session cannot reach `/api/daemon/stop`, and bringing the
            // backend back needs this Wi-Fi — so the greyed-out button says which.
            .reachy("Powering off needs the robot's own network.")
        } else {
            .reachy("Powering off stops the camera, the motors and the state stream. Wake up brings it back.")
        }
    }

    private var powerOffConfirmation: LocalizedStringResource {
        if let app = powerOff.runningApp(session) {
            .reachy("\(app.title) stops first, then the robot goes to sleep and its backend shuts down.")
        } else {
            .reachy("The robot goes to sleep first, then its backend shuts down.")
        }
    }

    private var isConnected: Bool {
        if case .connected = session.phase {
            return true
        }
        return false
    }
}
