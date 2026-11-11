import ReachyDesign
import ReachyKit
import SwiftUI

/// The two ways to reach a robot, one segment each, under a rail that says how the
/// current attempt is going — and the simulator behind a Developer disclosure below
/// them, for the reader who has no robot at all.
///
/// Two things stay out of the segments on purpose, and both are load-bearing:
///
/// - **Bluetooth setup**, because a robot that has never been on a network is
///   exactly the one keeping the sweep failing, and burying the way out behind a
///   segment the reader has no reason to open would be the wrong place for it.
/// - **`disabled` is applied section by section**, never to the form. It is
///   cumulative and a child cannot re-enable itself, so one modifier on the form
///   would take the Bluetooth button down with everything else — and the sweep it
///   waits on runs every 10 s forever when nothing answers.
///
/// A typed address is *inside* `local` rather than a segment of its own, and
/// `ConnectRoute` carries why.
struct ConnectionScreen: View {
    let session: RobotSession
    let progress: ConnectProgressModel
    /// Absent in previews and wherever the remote list has nowhere to be presented
    /// from, which is what hides that segment's content rather than a flag.
    var showRemoteRobots: (() -> Void)?
    /// Opens the privacy screen. Optional for the same reason as the list above —
    /// the sheet belongs to the root, and a leaf that reached for the router
    /// directly could not be previewed.
    var showPermissions: (() -> Void)?

    @Environment(\.reachyPreviewMode) private var previewMode
    /// Everything the gate shows that is its own. The screen owns it, so a gate that
    /// comes back after a disconnect starts from the stored address again.
    ///
    /// Built in `init` rather than defaulted here, and TN3211 is why: Xcode 27
    /// initialises `@State` lazily — back-deployed to iOS 17 — so a default
    /// expression runs at the property's first *access* instead of at the view's
    /// construction. The model reads mutable global state that `RobotSession`
    /// clears on the handshake (`ConnectGateModel.finishOnboarding` is the writer),
    /// so deferring the read to the first body evaluation is the difference between
    /// the banner appearing and never appearing. `manualInput` reads
    /// `KnownRobots.lastAddress` from the same position for the same reason.
    ///
    /// The three optional models are resolved in `ConnectGateModel.start` rather
    /// than defaulted here: a default argument is evaluated in a nonisolated
    /// context, and all three are main-actor isolated.
    @State private var model: ConnectGateModel

    init(
        session: RobotSession,
        progress: ConnectProgressModel,
        browser: RobotBrowser = RobotBrowser(),
        manualInput: String? = nil,
        knownRobots: KnownRobotsModel? = nil,
        sweep: CandidateSweep? = nil,
        localDaemon: LocalDaemonModel? = nil,
        route: ConnectRoute = .local,
        showsDeveloper: Bool = false,
        showRemoteRobots: (() -> Void)? = nil,
        showPermissions: (() -> Void)? = nil
    ) {
        self.session = session
        self.progress = progress
        self.showRemoteRobots = showRemoteRobots
        self.showPermissions = showPermissions
        _model = State(initialValue: ConnectGateModel(
            session: session,
            browser: browser,
            manualInput: manualInput ?? KnownRobots.lastAddress.map(\.displayString) ?? "",
            awaitedHardwareID: KnownRobots.pendingProvisionedHardwareID,
            knownRobots: knownRobots,
            sweep: sweep,
            localDaemon: localDaemon,
            route: route,
            showsDeveloper: showsDeveloper
        ))
    }

    var body: some View {
        Group {
            if case let .connecting(.needsDaemonUpdate(_, requirement)) = session.phase {
                // Its own screen rather than a rail node: retrying is pointless here,
                // and everything the user can do is an update decision.
                NavigationStack {
                    DaemonUpdateScreen(session: session, requirement: requirement)
                }
            } else {
                segmentedBody
            }
        }
        .onAppear(perform: appeared)
        .introspected(model)
        .sheet(isPresented: $model.showsOnboarding) {
            OnboardingFlow(onFinish: model.finishOnboarding) { model.showsOnboarding = false }
                .reachySheet()
        }
        .onChange(of: model.browser.services) { _, services in
            model.servicesChanged(services)
        }
        .onChange(of: session.phase, initial: true) { _, phase in
            progress.observe(phase)
        }
        .onDisappear {
            guard !previewMode else { return }
            model.stop()
        }
    }

    private var segmentedBody: some View {
        VStack(spacing: 0) {
            ConnectHeader(session: session, displayed: progress.displayed)
            ConnectRoutePicker(route: $model.route)
                .disabled(!session.phase.acceptsConnectionChoice)
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.sm)
            form
        }
        // The header sits outside the `Form`, so it takes whatever backdrop it finds
        // rather than the grouped one the form paints for itself. `ConnectGate` sets
        // this too, but a screen cannot rely on its container for its own background:
        // without it here the reference images record a white strip above a grey page
        // — a difference from the shipping app that the snapshots would then defend.
        .groupedPageBackground()
    }

    /// Whether to offer the daemon running on this very machine.
    ///
    /// A compile-time answer read as a runtime flag, which is `FloatingViewportModifier
    /// .hasTabBar`'s shape and is here for two reasons. `LocalDaemonSection` then
    /// compiles on every platform, so its three states can be captured on the iOS
    /// simulator the snapshot suite runs on — and a `#if` inside a `Form`'s builder
    /// has no precedent in this target, while this does.
    ///
    /// macOS only, and deliberately **not** `targetEnvironment(simulator)` even
    /// though `CandidateSweep.enqueueInitialCandidates()` pairs the two when seeding
    /// loopback. That suite runs on a simulator, so including it would put a row
    /// into every `Connection —` reference that a real iPhone never draws, and a
    /// reference is evidence about the shipping app or it is worse than nothing.
    /// The phone's half of the same information is `ManualAddressSection`'s footer;
    /// what stays uncovered is this mount point, and only this mount point.
    private var showsLocalDaemon: Bool {
        #if os(macOS)
            true
        #else
            false
        #endif
    }

    private var form: some View {
        Form {
            // First, and unconditional: a robot that has never been on a network is
            // the one keeping every list below empty, and the way out of that
            // belongs above the lists rather than after two screens of them.
            setUpSection
            switch model.route {
            case .local:
                if showsLocalDaemon, let localDaemon = model.localDaemon {
                    LocalDaemonSection(model: localDaemon, connect: model.connectManually)
                        .disabled(!session.phase.acceptsConnectionChoice)
                }
                NetworkRobotsSection(
                    session: session,
                    browser: model.browser,
                    entries: model.knownRobots?.entries ?? [],
                    connect: model.connectManually,
                    connectToService: model.connect(to:),
                    forget: { model.knownRobots?.forget($0) },
                    resolving: model.resolving
                )
                .disabled(!session.phase.acceptsConnectionChoice)
                // Under the list rather than a segment away, which is where its own
                // footer has always pointed: the reader who needs it is the one
                // watching that list stay empty.
                ManualAddressSection(input: $model.manualInput, connect: model.connectManually)
                    .disabled(!session.phase.acceptsConnectionChoice)
            case .account:
                // The one segment with no `disabled` on it, which is what its own
                // doc comment has always claimed. A robot reached through Hugging
                // Face is not on this Wi-Fi, so a sweep of this one says nothing
                // about whether it can be reached — and the sweep walks the phase
                // through `idle → handshaking → idle` every 10 s, so gating on it
                // made the only way to a remote robot go dead under a finger on a
                // beat the reader cannot see.
                YourReachiesSection(show: showRemoteRobots)
            }
            developerSection
            privacySection
            errorSection
        }
        .formStyle(.grouped)
    }

    /// The simulator, behind a disclosure. It is the answer for a reader who has no
    /// robot, and that reader is not the one this screen is for; as a segment it
    /// put "start something that is not a robot" on the app's first screen, and the
    /// smoke test walked into it every run. Opened by hand, never remembered.
    private var developerSection: some View {
        Section {
            DisclosureGroup(isExpanded: $model.showsDeveloper) {
                SimulatorSection(
                    isConnecting: !session.phase.acceptsConnectionChoice,
                    connect: model.connectToSimulator
                )
            } label: {
                // On the label, never on the group: an identifier on a
                // `DisclosureGroup` reaches every row it discloses and overrides
                // theirs — `Start the simulator` came back as `connect.developer`.
                Label(.reachy("Developer"), systemImage: "hammer")
                    .accessibilityIdentifier(.connectDeveloper)
            }
        }
    }

    /// Outside the segments, for the same reason `setUpSection` is: a refused Local
    /// Network permission breaks *every* route, and the banner used to live inside
    /// `NetworkRobotsSection` where only one of them could show it. Someone blocked
    /// from discovery reaches for the address field next — which was a segment away
    /// at the time, and is now the section directly below, but either way it failed
    /// just as silently, because the permission gates plain HTTP to the LAN and not
    /// only Bonjour.
    ///
    /// The heartbeat question this screen's `AGENTS.md` insists on: nothing here keys
    /// off `session.phase` or `lastError`, so nothing mounts and unmounts on the 10 s
    /// sweep. `permissionLooksDenied` flips at most once in a browser's life.
    private var privacySection: some View {
        Section {
            if model.browser.permissionLooksDenied {
                Label(.reachy("Local Network permission denied"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Tone.danger.style)
                PrivacySettingsButton(pane: .localNetwork)
            }
            if let showPermissions {
                Button(.reachy("Privacy permissions"), action: showPermissions)
            }
        } footer: {
            if model.browser.permissionLooksDenied {
                Text(.reachy("Without it this app cannot find the robot or reach it at a typed address."))
            }
        }
    }

    /// The last error, shown only once the sweep has stopped rewriting it.
    ///
    /// `beginAttempt` clears `lastError` and `failAttempt` sets it — for automatic
    /// attempts too, since the guard that keeps the phase on `.idle` comes after the
    /// assignment. So while the sweep is running this section mounts and unmounts
    /// every 10 s, which was the second half of the reported jitter and survived the
    /// stepper being taken out of the form.
    ///
    /// Suppressing it there loses nothing: a failure the reader triggered is already
    /// named on the rail's own detail line, and one from a background retry says
    /// `Could not connect to the server` about an address nobody chose, under a list
    /// that already reads "Searching…" with two paragraphs explaining it.
    @ViewBuilder
    private var errorSection: some View {
        if let error = session.robotError, !session.automaticConnectionAllowed {
            // The rail's own "Try again" is the retry, so the row carries none.
            Section {
                ReachyErrorRow(error)
            }
        }
        // Separate from the robot's own error, and shown regardless of
        // `automaticConnectionAllowed`: nothing was asked of a robot here, so
        // nothing about a robot is being retried.
        if let simulatorError = model.simulatorError {
            Section {
                ReachyErrorRow(simulatorError)
            }
        }
    }

    /// Its own section so the sweep cannot switch it off, and outside the segments
    /// so no choice of segment can hide it.
    private var setUpSection: some View {
        Section {
            if let awaitedHardwareID = model.awaitedHardwareID {
                Label(
                    .reachy(
                        // swiftlint:disable:next line_length
                        "Waiting for the robot you just set up (\(awaitedHardwareID)). If this phone is still on reachy-mini-ap, switch it back to your home Wi-Fi."
                    ),
                    systemImage: "clock.arrow.circlepath"
                )
                .font(Typography.status)
                .foregroundStyle(Tone.quiet.style)
            }
            Button {
                model.showsOnboarding = true
            } label: {
                Label(.reachy("Set up a new robot over Bluetooth"), systemImage: "antenna.radiowaves.left.and.right")
            }
            .accessibilityIdentifier(.connectBluetoothSetup)
        }
    }

    private func appeared() {
        guard !previewMode else { return }
        model.start(offersLocalDaemon: showsLocalDaemon)
    }
}

extension RobotSession.ConnectionPhase {
    /// A connection choice may start only while no attempt or decision is active.
    /// The setup-over-Bluetooth section does not read this value and deliberately
    /// remains available while an automatic attempt is failing.
    var acceptsConnectionChoice: Bool {
        if case .idle = self {
            true
        } else {
            false
        }
    }
}
