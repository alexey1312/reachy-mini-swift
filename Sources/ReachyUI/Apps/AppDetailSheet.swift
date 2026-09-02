import ReachyDesign
import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// One app, and everything that can be done to it — **the only page about an
/// app there is**.
///
/// It used to be two. A store card carried install, update, remove and
/// start-on-wake-up; a separate running-app sheet carried the process state,
/// restart, stop and the app's own settings. They were split because the store
/// card needs models the root does not own — which is a fact about this file's
/// dependencies, not about the app the user is looking at. From the reader's side
/// there was one object with two pages, each missing half of it, and the running
/// one was missing the half that identifies it: the icon, the title and the
/// description all live in metadata the daemon leaves off a running-app status
/// (`RobotSession.describedFromInstalled`).
///
/// So the store row and the dock now open this, and which sections appear is
/// decided by the app's state rather than by which surface asked.
///
/// The job runs here rather than behind the sheet: an install takes a minute of
/// `uv pip install` output, and a user who dismissed the sheet would have nothing
/// to come back to.
struct AppDetailSheet: View {
    let app: RobotApp
    let model: AppStoreModel
    let session: RobotSession
    let install: AppInstallModel
    let runningApp: RunningAppModel
    let dismiss: () -> Void

    @State private var confirmingRemoval = false
    @Environment(\.reachyPreviewMode) private var previewMode

    /// The running app, but only when it is *this* one.
    ///
    /// Read off the session rather than through `model.isRunning(_:)`, which needs
    /// the installed list: opened from the dock this sheet may be the first thing
    /// on screen, before the store has ever loaded. The name is the daemon's own
    /// join key, and `matches(installed:)` covers a catalogue entry whose Space
    /// slug differs from its Python entry point.
    private var runningStatus: RobotAppStatus? {
        guard let status = runningApp.visibleStatus(for: session),
              status.app.name == app.name || app.matches(installed: status.app)
        else { return nil }
        return status
    }

    /// Whether Start is on screen: the asleep footer is a sentence about it, and
    /// must not appear over an Install.
    private var offersStart: Bool {
        installedApp != nil && runningStatus?.isBusy != true
    }

    private var isReachable: Bool {
        runningApp.isReachable(session)
    }

    /// This app, stuck in a transition long past its deadline.
    ///
    /// Matched against the app `runningStatus` already resolved to, so a wedge
    /// belonging to some other app never speaks for this page.
    private var isWedged: Bool {
        guard let wedged = runningApp.wedged, let status = runningStatus else { return false }
        return wedged.app.name == status.app.name
    }

    /// The app's own settings page, when there is one to offer.
    ///
    /// `session.appSettingsURL(for:)` already answers nil without a declared port
    /// and without a LAN address; the two conditions added here are this screen's
    /// own. **Only while it is running**, because the process serving that page is
    /// the process that would have died — a crashed app takes its settings down
    /// with it, which is at its worst exactly when a bad setting is what crashed
    /// it. And only while the robot answers, so the row does not lead to a spinner
    /// that can never resolve.
    private var settingsURL: URL? {
        guard let status = runningStatus, status.state == .running, isReachable else { return nil }
        return session.appSettingsURL(for: status.app)
    }

    var body: some View {
        Form {
            Section {
                AppIdentityHeader(app: app, primary: primaryAction)
            }

            if let status = runningStatus {
                statusSection(status)
            }

            if let job = jobForThisApp {
                Section(.reachy("Progress")) {
                    JobProgressRow(state: job)
                    if install.isBusy || !install.log.entries.isEmpty {
                        LogConsoleView(
                            model: install.log,
                            source: app.title,
                            // The socket only wakes on a new line, so silence here
                            // is normal rather than a stall — `AppJobMonitor` is
                            // polling regardless.
                            emptyDescription: String(localized: .reachy("Waiting for the robot to report progress…"))
                        )
                        .frame(minHeight: 160)
                    }
                }
            } else {
                // Only the stopped-backend half of the banner reaches this screen:
                // Start wakes a sleeping robot itself. A stopped backend is a 90 s job.
                if !session.isBackendRunning {
                    Section { AsleepBanner(session: session) }
                }
                actions
            }

            if let settingsURL {
                Section {
                    NavigationLink {
                        AppSettingsScreen(url: settingsURL)
                    } label: {
                        Label(.reachy("Settings"), systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text(.reachy("The app's own page, served by the robot on this network."))
                }
            }

            if let summary = app.summary {
                Section(.reachy("About")) {
                    Text(summary)
                        .font(Typography.subtitle)
                }
            }

            if let spaceID = app.spaceID, let url = URL(string: "https://huggingface.co/spaces/\(spaceID)") {
                Section {
                    Link(destination: url) {
                        Label(.reachy("View on Hugging Face"), systemImage: "arrow.up.forward.square")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(app.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // "Minimize" while the app holds the robot: closing this page
                    // leaves it running, and only Stop ends it. That is the
                    // contract a Telegram Mini App has, and the dock is where it
                    // minimises to.
                    Button(runningStatus == nil ? .reachy("Done") : .reachy("Minimize")) {
                        install.dismiss()
                        dismiss()
                    }
                    .disabled(install.isBusy)
                }
            }
            .task {
                guard !previewMode else { return }
                await model.loadInstalledIfNeeded(session: session)
            }
            .interactiveDismissDisabled(install.isBusy)
            .confirmationDialog(
                .reachy("Remove \(app.title)?"),
                isPresented: $confirmingRemoval,
                titleVisibility: .visible
            ) {
                Button(.reachy("Remove"), role: .destructive) {
                    perform(.remove(installedApp ?? app))
                }
            } message: {
                Text(.reachy("The app and its Python environment are deleted from the robot."))
            }
    }

    /// What the robot is doing with this app right now, and the two controls that
    /// change it. Stop lives here rather than among the install actions: it acts on
    /// the process, not on the copy installed on the robot.
    private func statusSection(_ status: RobotAppStatus) -> some View {
        Section(.reachy("Status")) {
            LabeledContent(.reachy("State")) {
                // `.body` and not a `Typography` role: here the state is the
                // *value* of a form row, so it takes the size the row's own
                // label already has.
                //
                // `.shownSeparately` because `failureRow` is right below with
                // the whole tail in it — inlining the crash here printed the
                // same text twice, once cut off after two lines.
                RunningAppCaption.label(
                    of: status,
                    failure: .shownSeparately,
                    conversationTurn: runningApp.conversationTurn,
                    isReachable: isReachable,
                    wedged: isWedged,
                    font: .body
                )
            }
            if isWedged {
                WedgedAppNotice(state: status.state)
            }
            if !isReachable {
                Text(
                    .reachy(
                        // swiftlint:disable:next line_length
                        "The robot stopped answering. The app may still be running — these controls cannot reach it."
                    )
                )
                .font(Typography.status)
                .foregroundStyle(.secondary)
            }
            if let error = status.error {
                failureRow(error)
            }
            if let lastError = runningApp.lastError {
                Text(lastError)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
            }
            processControls(status)
        }
    }

    /// The last thing the app printed before it died. The daemon keeps ten stderr
    /// lines here, and on a robot whose journal is not served over the network this
    /// is the only crash output there is.
    private func failureRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(.reachy("Last output"))
                .font(Typography.status.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(error)
                .font(Typography.consoleLine)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func processControls(_ status: RobotAppStatus) -> some View {
        if status.state == .error {
            Button(.reachy("Dismiss"), systemImage: "xmark") {
                runningApp.dismissFailure(session)
            }
        } else {
            // Both are refused identically once the slot is wedged: the daemon
            // raises on `STOPPING`, and restart calls stop first. `WedgedAppNotice`
            // above says why they are out, so this is a disabled control with a
            // reason attached rather than one without.
            Button(.reachy("Restart"), systemImage: "arrow.clockwise") {
                Task { await runningApp.restart(session: session) }
            }
            .disabled(runningApp.busy || !isReachable || isWedged)

            Button(.reachy("Stop"), systemImage: "stop.fill", role: .destructive) {
                Task { await runningApp.stop(session: session) }
            }
            .disabled(runningApp.busy || !isReachable || isWedged)
        }
    }

    /// Install for an app the robot does not have, Start for one it does and is
    /// not already running (`isBusy`, not "has a status": a crashed app keeps one
    /// so its output stays readable); nothing while a job is on screen. Starting
    /// evicts whatever holds the robot, which the daemon refuses with a 400, and
    /// a remote session is not ours to take; the power conditions have their
    /// reason attached in the banner above and the footer below.
    private var primaryAction: AppIdentityHeader.Primary? {
        guard jobForThisApp == nil else { return nil }
        if installedApp != nil {
            guard runningStatus?.isBusy != true else { return nil }
            return AppIdentityHeader.Primary(
                title: .reachy("Start"),
                systemImage: "play.fill",
                isEnabled: !(
                    model.busy || model.isHeldRemotely || model.runningApp?.isBusy == true
                        || !session.isBackendRunning || session.powerTransition != nil
                )
            ) {
                Task { await model.start(app, session: session) }
            }
        }
        return AppIdentityHeader.Primary(
            title: .reachy("Install"),
            systemImage: "arrow.down.circle.fill",
            isEnabled: !(app.isPrivate && !canInstallPrivately)
        ) {
            perform(.install(app))
        }
    }

    /// What is not the one action: the transition in progress, Update, the wake-up
    /// switch and Remove — and, in the footer, why the header's button is greyed.
    private var actions: some View {
        Section {
            if let installed = installedApp {
                if let transition = session.powerTransition {
                    PowerTransitionRow(transition: transition)
                }
                if model.hasUpdate(app) {
                    Button(.reachy("Update"), systemImage: "arrow.down.circle") {
                        perform(.update(installed))
                    }
                }
                Toggle(.reachy("Start on wake-up"), isOn: startupBinding)
                    .disabled(model.busy)
                Button(.reachy("Remove"), systemImage: "trash", role: .destructive) {
                    confirmingRemoval = true
                }
            }
        } footer: {
            if app.isPrivate, !canInstallPrivately {
                Text(
                    .reachy(
                        "A private Space can only be installed once this robot is linked to your Hugging Face account."
                    )
                )
            } else if model.isHeldRemotely {
                Text(.reachy("Someone is driving this robot over Hugging Face right now."))
            } else if session.isBackendRunning, !session.isAwake, offersStart {
                Text(.reachy("Reachy Mini is asleep. Starting an app wakes it up first."))
            }
        }
    }

    private var installedApp: RobotApp? {
        model.installedTwin(of: app)
    }

    /// The daemon fetches a private Space with the token it stores, so this is
    /// about the *robot's* account, not about being signed in on this device.
    private var canInstallPrivately: Bool {
        session.canLinkHuggingFace
    }

    private var jobForThisApp: AppInstallModel.State? {
        guard let operation = install.operation else { return nil }
        let subject = operation.app
        guard subject.id == app.id || subject.name == installedApp?.name else { return nil }
        return install.state
    }

    private var startupBinding: Binding<Bool> {
        Binding(
            get: { model.isStartupApp(app) },
            set: { isOn in
                Task { await model.setStartupApp(isOn ? app : nil, session: session) }
            }
        )
    }

    private func perform(_ operation: AppInstallModel.Operation) {
        guard !previewMode else { return }
        Task {
            await install.perform(operation)
            await model.reloadInstalled(session: session)
        }
    }
}
