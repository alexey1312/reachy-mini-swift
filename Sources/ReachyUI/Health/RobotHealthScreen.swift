import ReachyDesign
import ReachyKit
import ReachySSH
import SwiftUI

/// What the robot is doing to itself, as opposed to what it is doing for you.
///
/// A screen of its own rather than a section on the Robot tab, and the split of
/// **what** it shows is what earns it: two sources that fail independently, one
/// costing nothing and one costing an SSH session. A section would have had to
/// carry both the sign-in and the failure inline on the tab the app opens on, and
/// would have held a connection to the robot open for as long as the app was
/// connected. Here the reading starts when the screen is opened and stops when it
/// is left.
///
/// The two sections are named after their sources on purpose. Where a number comes
/// from decides whether it can be trusted when the other half is missing, and a
/// reader looking at a robot that has stopped answering needs to see which half
/// stopped.
struct RobotHealthScreen: View {
    @State private var model: RobotHealthModel
    @State private var isSigningIn = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.reachyPreviewMode) private var previewMode

    /// Adopted into `@State` rather than held by the caller, the shape
    /// `RobotFilesScreen` uses: `NavigationLink` builds its destination eagerly and
    /// re-runs the closure on every update of the screen it hangs off, so a model
    /// passed straight through would be replaced mid-session — with its history and
    /// its live SSH session.
    init(model: RobotHealthModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Form {
            controlLoopSection
            motionSection
            systemSection
        }
        .formStyle(.grouped)
        .navigationTitle(.reachy("State"))
        .refreshable {
            guard !previewMode else { return }
            await model.refreshIMU()
        }
        .task {
            // A frozen preview must not open a socket.
            guard !previewMode else { return }
            await model.refreshIMU()
            await model.start()
        }
        // Unlike the daemon's half, which rides a status the session fetches
        // anyway, this one holds a TCP connection open and reads five files off the
        // robot every few seconds. Worth nothing at all with the app in the
        // background — the same gate `RunningAppDock` puts on its poll — or with
        // the screen closed. The readings already taken stay put rather than
        // blanking, so coming back shows the last known values while it reconnects.
        .onChange(of: scenePhase) { _, phase in
            guard !previewMode else { return }
            Task {
                if phase == .active {
                    await model.start()
                } else {
                    await model.stop()
                }
            }
        }
        .onDisappear {
            guard !previewMode else { return }
            Task { [model] in await model.stop() }
        }
        .sheet(isPresented: $isSigningIn) { signIn }
    }

    // MARK: - The daemon's half

    private var controlLoopSection: some View {
        Section {
            controlLoopRows
        } header: {
            Text(.reachy("Control loop"))
        } footer: {
            Text(controlLoopFooter)
        }
    }

    /// The rows drop "loop" and "motor" from their names because the section
    /// already carries both. A row reading `Control loop › Loop errors` says the
    /// same word twice and squeezes the number that matters.
    @ViewBuilder
    private var controlLoopRows: some View {
        if let loop = model.loop {
            let nominal = HealthMetric.nominalFrequency(observed: model.frequency.values.max())
            MetricRow(
                title: .reachy("Rate"),
                value: loop.frequencyHz.map(HealthFormat.hertz),
                series: model.frequency,
                domain: HealthMetric.frequencyDomain(nominal: nominal),
                level: loop.frequencyHz.map { HealthLevel.frequency($0, nominal: nominal) } ?? .normal
            )
            // The mean hides a stall; this is what shows one. A loop averaging its
            // nominal rate with a 300 ms gap in it is a robot that jerked.
            if let gap = loop.maxIntervalSeconds {
                LabeledContent(.reachy("Longest gap"), value: HealthFormat.milliseconds(gap))
            }
            if let errors = loop.errorCount {
                LabeledContent(.reachy("Errors"), value: errors.formatted())
                    .foregroundStyle(errors > 0 ? Tone.warning.style : AnyShapeStyle(.primary))
            }
            // Free-form daemon text, below its label rather than beside it: the field
            // is named `motor_controller` and daemon 1.9.0 fills it with
            // `str(self.c.get_stats())` — on a real robot,
            // `ControlLoopStats(period=~20.02ms, read_dt=~1.95 ms, write_dt=~0.44 ms)`.
            // A name would fit in a value column and that sentence does not.
            if let controller = loop.motorController {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(.reachy("Motor controller"))
                    Text(controller)
                        .font(Typography.consoleLine)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } else {
            // Reached by a simulated backend on this network: no loop to report, and
            // the operating system below is still worth the trip.
            Text(.reachy("This robot's backend reports no control loop."))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - What the robot feels

    /// Absent rather than empty on the three robots that report no IMU — a Lite
    /// unit, the simulator and a relayed session. A section headed "Motion" over
    /// two dashes would read as a sensor that broke.
    @ViewBuilder
    private var motionSection: some View {
        if let imu = model.imu {
            Section {
                if let tilt = imu.tiltDegrees {
                    LabeledContent(.reachy("Lean"), value: HealthFormat.degrees(tilt))
                }
                LabeledContent(.reachy("Sensor"), value: HealthFormat.celsius(imu.temperatureCelsius))
            } header: {
                Text(.reachy("Motion"))
            } footer: {
                Text(.reachy("Read when this screen opens, and again when you pull it down."))
            }
        }
    }

    // MARK: - The operating system's half

    private var systemSection: some View {
        Section {
            systemRows
            accessRow
        } header: {
            Text(.reachy("System"))
        } footer: {
            Text(systemFooter)
        }
    }

    @ViewBuilder
    private var systemRows: some View {
        if model.phase == .sampling, !model.system.isEmpty {
            let system = model.system
            MetricRow(
                title: .reachy("Processor"),
                value: system.cpuPercent.map(HealthFormat.percent),
                series: model.cpu,
                domain: HealthMetric.percent,
                level: system.cpuPercent.map(HealthLevel.cpu) ?? .normal
            )
            MetricRow(
                title: .reachy("Memory"),
                value: HealthFormat.memory(system),
                series: model.memory,
                domain: HealthMetric.percent,
                level: system.memoryPercent.map(HealthLevel.memory) ?? .normal
            )
            MetricRow(
                title: .reachy("Temperature"),
                value: system.cpuTemperatureCelsius.map(HealthFormat.celsius),
                series: model.temperature,
                domain: HealthMetric.temperature,
                level: system.cpuTemperatureCelsius.map(HealthLevel.temperature) ?? .normal
            )
            if let load = system.loadAverage1m {
                LabeledContent(.reachy("Load average"), value: HealthFormat.loadAverage(load))
            }
            if let uptime = system.uptime {
                LabeledContent(.reachy("Uptime"), value: HealthFormat.uptime(uptime))
            }
        }
    }

    /// The one row that changes what the reader can do, rather than telling them
    /// something. Absent over the relay, where there is nothing to offer.
    @ViewBuilder
    private var accessRow: some View {
        switch model.phase {
        case .unavailable, .sampling:
            EmptyView()
        case .needsPassword:
            Button {
                isSigningIn = true
            } label: {
                Label(
                    .reachy("Show processor, memory and temperature"),
                    systemImage: "gauge.with.dots.needle.bottom.50percent"
                )
            }
        case .connecting:
            HStack(spacing: Space.sm) {
                ProgressView()
                Text(.reachy("Signing in over SSH…"))
                    .foregroundStyle(.secondary)
            }
        case .confirmHostKey, .hostKeyChanged:
            Button {
                isSigningIn = true
            } label: {
                Label(.reachy("Confirm the robot's identity key"), systemImage: "key.radiowaves.forward")
                    .foregroundStyle(Tone.warning.style)
            }
        case let .failed(reason):
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(reason)
                    .font(Typography.detail)
                    .foregroundStyle(Tone.danger.style)
                Button(.reachy("Try again")) { Task { await model.connect() } }
            }
        }
    }

    private var signIn: some View {
        NavigationStack {
            switch model.phase {
            case let .confirmHostKey(fingerprint):
                HostKeyConfirmation(situation: .firstContact(fingerprint)) {
                    Task {
                        await model.trustOfferedKey()
                        isSigningIn = model.phase != .sampling
                    }
                }
            case let .hostKeyChanged(pinned, offered):
                HostKeyConfirmation(situation: .changed(pinned: pinned, offered: offered)) {
                    Task {
                        await model.trustOfferedKey()
                        isSigningIn = model.phase != .sampling
                    }
                }
            default:
                SSHPasswordForm(
                    username: $model.username,
                    password: $model.password,
                    error: model.lastError
                ) {
                    Task {
                        await model.connect()
                        // Stays up for a refused password and for a key that has to
                        // be confirmed — both are answered in this sheet.
                        isSigningIn = model.phase != .sampling
                    }
                }
                .navigationTitle(.reachy("Robot access"))
            }
        }
        .reachySheet()
    }

    private var controlLoopFooter: LocalizedStringResource {
        .reachy("Measured by the daemon once a second. The rate is what the robot's motors are actually driven at.")
    }

    private var systemFooter: LocalizedStringResource {
        switch model.phase {
        case .unavailable:
            // Not an error and not a thing to retry: SSH needs a TCP route to port
            // 22 and the Hugging Face relay carries WebRTC (ADR 0003).
            .reachy("Processor, memory and temperature need a connection on this network.")
        case .needsPassword, .confirmHostKey, .hostKeyChanged:
            .reachy("The daemon reports none of this. It is read from the robot's own system over SSH.")
        default:
            .reachy("Read from the robot every few seconds, while this screen is open.")
        }
    }
}
