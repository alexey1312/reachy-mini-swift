import ReachyDesign
import ReachyKit
import ReachySSH
import SwiftUI

/// Connected-robot controls: identity, live daemon status, wake/sleep, audio.
///
/// The navigation container is the host's — this is a column on iPad and Mac and
/// a tab on iPhone, and both supply their own `NavigationStack`.
struct RobotScreen: View {
    let session: RobotSession

    @State private var powerOff = RobotPowerOffModel()
    /// Built once the robot has an identity to key its Keychain items by, not in
    /// `init`: this screen is rebuilt on every status poll, and each rebuild would
    /// otherwise construct an `SSHFileSystem` for `@State` to throw away.
    @State private var health: RobotHealthModel?

    init(session: RobotSession, health: RobotHealthModel? = nil) {
        self.session = session
        _health = State(initialValue: health)
    }

    var body: some View {
        Form {
            statusSection
            controlSection
            if let warning = session.compatibilityWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.warning.style)
                }
            }
            if let error = session.robotError {
                // No retry beside it: the Link row above reconnects on its own, and a
                // second button here would race the sweep it reports on.
                Section {
                    ReachyErrorRow(error)
                }
            }
            Section {
                Button(.reachy("Disconnect"), role: .destructive) {
                    session.disconnect()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(identity?.name ?? String(localized: .reachy("Robot")))
        .task { prepareHealth() }
        // Kept warm from here rather than from the screen, and it costs nothing:
        // the status is polled whether or not anyone is looking at the loop. So the
        // sparkline is already a line when the screen opens, instead of taking
        // three minutes to become one.
        .onChange(of: session.lastStatus?.controlLoop, initial: true) { _, loop in
            health?.record(loop: loop)
        }
    }

    /// Absent when there is nothing at all to show: a relayed session to a robot
    /// whose backend reports no loop either. Both halves gone is the one case where
    /// the screen would open on nothing.
    @ViewBuilder
    private var healthLink: some View {
        if let health, health.phase != .unavailable || session.lastStatus?.controlLoop != nil {
            NavigationLink {
                RobotHealthScreen(model: health)
            } label: {
                LabeledContent(.reachy("State"), value: healthSummary)
            }
        }
    }

    /// The one number that is free to know. Processor and temperature would each
    /// cost an SSH session held open for a row nobody has asked to see.
    private var healthSummary: String {
        session.lastStatus?.controlLoop?.frequencyHz.map(HealthFormat.hertz) ?? "—"
    }

    /// One model for the life of this screen.
    ///
    /// Nil `files` is what a relayed session gets, and it is the same gate
    /// `filesLink` uses: SSH needs a TCP route to port 22 and the Hugging Face relay
    /// carries WebRTC, not a tunnel (ADR 0003). The model then reports
    /// `.unavailable` and the section says so instead of offering a sign-in that
    /// could not connect.
    private func prepareHealth() {
        guard health == nil else { return }
        guard let robot = identity?.deduplicationKey else { return }
        health = RobotHealthModel(
            readIMU: { [session] in try await session.imuReading() },
            files: session.address.map { _ in SSHFileSystem(robot: robot) },
            robot: robot,
            host: session.address?.host ?? ""
        )
    }

    private var identity: RobotIdentity? {
        switch session.phase {
        case let .connected(identity), let .unreachable(identity): identity
        default: nil
        }
    }

    /// How long the robot took to answer its last status poll.
    ///
    /// In the Link row because the five tabs each carry their own bar and there is no
    /// persistent header to put it in. Absent rather than dashed when there is no
    /// figure: the branch above already says "unreachable" in words.
    @ViewBuilder
    private var roundTrip: some View {
        if let duration = session.lastRoundTrip {
            Text(verbatim: HealthFormat.milliseconds(duration))
                .font(Typography.status)
                .monospacedDigit()
                .foregroundStyle(HealthLevel.roundTrip(duration).tone.style)
        }
    }

    /// Which kind of robot answered — and the one positive statement about it
    /// anywhere in the app.
    ///
    /// Until this row existed a Lite robot and a simulator announced themselves only
    /// by what was *missing*: `supportsWirelessFeatures` takes the Wi-Fi and update
    /// cards away, `canPerformMaintenance` takes the maintenance one, and nothing
    /// said why. Absence is a bad way to learn a fact.
    ///
    /// **Absent over the relay**, which is the one flavour that would repeat itself:
    /// the Connection row two lines down already reads "Hugging Face relay", and a
    /// second row saying the same words under a different label teaches nothing.
    /// `DaemonFlavourCaption` still names that case — a total mapping is what keeps
    /// the decision here rather than scattered — and `Robot — over the relay` is what
    /// captures the row's absence, along with `Robot — nothing reported`, whose
    /// session has no status at all. A reference for the row's presence alone could
    /// tell neither from a row that is always there.
    @ViewBuilder
    private var modelRow: some View {
        if let flavour = session.flavour, flavour != .remote {
            LabeledContent(
                .reachy("Model"),
                value: String(localized: DaemonFlavourCaption.text(for: flavour))
            )
        }
    }

    private var statusSection: some View {
        Section(.reachy("Robot")) {
            LabeledContent(.reachy("Name"), value: identity?.name ?? "—")
            modelRow
            LabeledContent(.reachy("Daemon"), value: identity?.daemonVersion ?? "—")
            LabeledContent(.reachy("Connection"), value: ConnectionLinkCaption.text(for: session.link))
            if let status = session.lastStatus {
                LabeledContent(
                    .reachy("Daemon state"),
                    value: String(localized: DaemonStateCaption.text(for: status.state))
                )
                // A `disabled` robot answers every motion command and stays limp,
                // so the motor mode belongs next to the daemon state.
                if let mode = status.backendStatus?.value1?.motorControlMode {
                    LabeledContent(.reachy("Motors"), value: String(localized: MotorModeCaption.text(for: mode)))
                }
            }
            HStack {
                Text(.reachy("Link"))
                Spacer()
                if case .unreachable = session.phase {
                    Label(.reachy("Unreachable — reconnecting…"), systemImage: "wifi.exclamationmark")
                        .foregroundStyle(Tone.warning.style)
                } else if !session.isBackendRunning {
                    // Reachable but not drivable: claiming a green "Connected" here
                    // is what sent users looking for a network problem they don't have.
                    Label(.reachy("Backend stopped"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.warning.style)
                } else {
                    Label(.reachy("Connected"), systemImage: "checkmark.circle")
                        .foregroundStyle(Tone.success.style)
                    roundTrip
                }
            }
            if let fault = session.backendFault {
                Label(fault, systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(Tone.warning.style)
                    .font(Typography.detail)
            }
            healthLink
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
