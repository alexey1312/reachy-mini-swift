import AppIntents
import ReachyDesign
import ReachyKit
import ReachySSH
import ReachyWidgetUI
import SwiftUI

/// The connected robot: what it is doing, the one control that changes that, and
/// who it is — in that order, because that is the order a reader needs them in.
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
            identitySection
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
        .readablePage()
        // The robot this tab is about, so "put this one to sleep" needs no name.
        // `deduplicationKey` rather than the display name: it is `RobotEntity.id`
        // and the key every App Group store is already written against, so the
        // entity and the snapshot name the same robot with no join.
        .onscreenEntity(identity.map { EntityIdentifier(for: RobotEntity.self, identifier: $0.deduplicationKey) })
        .navigationTitle(identity?.name ?? String(localized: .reachy("Robot")))
        // Wake and sleep are long enough to look away from: the end of either is a
        // tick, and a refused one is a different tick.
        .sensoryFeedback(trigger: session.powerTransition == nil) { wasIdle, isIdle in
            guard !wasIdle, isIdle else { return nil }
            return session.robotError == nil ? .success : .error
        }
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

    /// What the robot is doing right now, first. The identity rows used to sit
    /// above this, so a reader opening the tab to find out why nothing moved read
    /// the name, the model and a version number before the one line that said.
    private var statusSection: some View {
        Section(.reachy("Status")) {
            HStack {
                Text(.reachy("Link"))
                Spacer()
                if case .unreachable = session.phase {
                    Label(.reachy("Unreachable — reconnecting…"), systemImage: "wifi.exclamationmark")
                        .foregroundStyle(Tone.warning.style)
                } else if !session.isBackendRunning {
                    // Reachable but not drivable: claiming a green "Connected" here
                    // is what sent users looking for a network problem they don't have.
                    Label(.reachy("Motors and camera off"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Tone.warning.style)
                } else {
                    Label(.reachy("Connected"), systemImage: "checkmark.circle")
                        .foregroundStyle(Tone.success.style)
                    roundTrip
                }
            }
            if let status = session.lastStatus {
                LabeledContent(
                    .reachy("Software"),
                    value: String(localized: DaemonStateCaption.text(for: status.state))
                )
            }
            if let fault = session.backendFault {
                Label(fault, systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(Tone.warning.style)
                    .font(Typography.detail)
            }
            healthLink
        }
    }

    /// Who the robot is, after what it is doing. "Software version" rather than
    /// "Daemon": the word names a process, and nothing on this screen asks the
    /// reader to know there is one.
    private var identitySection: some View {
        Section(.reachy("Robot")) {
            LabeledContent(.reachy("Name"), value: identity?.name ?? "—")
            modelRow
            LabeledContent(.reachy("Software version"), value: identity?.daemonVersion ?? "—")
            LabeledContent(.reachy("Connection"), value: ConnectionLinkCaption.text(for: session.link))
            // A `disabled` robot answers every motion command and stays limp, so
            // the motor mode is a fact about the robot worth a row of its own.
            if let mode = session.lastStatus?.backendStatus?.value1?.motorControlMode {
                LabeledContent(.reachy("Motors"), value: String(localized: MotorModeCaption.text(for: mode)))
            }
        }
    }

    /// One row of state with the one action that changes it, instead of Wake up and
    /// Go to sleep side by side — of which one was always the wrong one, and both
    /// were greyed only during a transition. Power off keeps a row of its own
    /// because it is the one that asks first.
    private var controlSection: some View {
        Section {
            if let transition = session.powerTransition {
                PowerTransitionRow(transition: transition)
            } else {
                powerRow
            }
            Button(role: .destructive) {
                powerOff.isConfirming = true
            } label: {
                Label(.reachy("Power off"), systemImage: "power")
            }
            .disabled(!powerOff.canPowerOff(session))
        } header: {
            Text(.reachy("Control"))
        } footer: {
            Text(powerOffDescription)
        }
        .disabled(!isConnected)
        .confirmationDialog(
            Text(.reachy("Power off the robot?")),
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

    /// The state in words on the left, the way out of it on the right. A stopped
    /// backend and a sleeping robot both wake: `wake()` starts the motors and
    /// camera first where they are off.
    @ViewBuilder
    private var powerRow: some View {
        if !session.isBackendRunning {
            LabeledContent {
                Button(.reachy("Wake up")) { Task { await session.wake() } }
            } label: {
                Label(.reachy("Motors and camera off"), systemImage: "moon.zzz")
            }
        } else if session.isAwake {
            LabeledContent {
                Button(.reachy("Go to sleep")) { Task { await session.sleep() } }
            } label: {
                Label(.reachy("Awake"), systemImage: "sun.max")
            }
        } else {
            LabeledContent {
                Button(.reachy("Wake up")) { Task { await session.wake() } }
            } label: {
                Label(.reachy("Asleep"), systemImage: "moon.zzz")
            }
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
            .reachy("\(app.title) stops first, then the robot goes to sleep and its motors and camera shut down.")
        } else {
            .reachy("The robot goes to sleep first, then its motors and camera shut down.")
        }
    }

    private var isConnected: Bool {
        if case .connected = session.phase {
            return true
        }
        return false
    }
}
