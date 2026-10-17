import ReachyDesign
import ReachyKit
import SwiftUI

/// The gate: robots on this network on one side, what is happening on the other.
///
/// Two of the connect steps are decisions rather than progress — a stopped backend and
/// a daemon too old to talk to — and those take the screen over, because the reader has
/// to choose before anything else is worth doing.
struct TVConnectScreen: View {
    let session: RobotSession
    @State private var model: TVConnectionModel

    init(session: RobotSession) {
        self.session = session
        _model = State(initialValue: TVConnectionModel(session: session))
    }

    var body: some View {
        Group {
            switch session.phase {
            case let .connecting(.backendUnavailable(identity, _)):
                TVBackendStoppedView(session: session, identity: identity)
            case let .connecting(.needsDaemonUpdate(identity, requirement)):
                TVDaemonUpdateView(session: session, identity: identity, requirement: requirement)
            default:
                chooser
            }
        }
        .task {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: model.browser.services) {
            model.servicesChanged()
        }
    }

    private var chooser: some View {
        HStack(alignment: .top, spacing: TVMetrics.gutter) {
            VStack(alignment: .leading, spacing: TVMetrics.group) {
                Text(verbatim: Bundle.main.displayName)
                    .font(Typography.screenTitle.bold())
                status
                Spacer()
                Text(.reachy("The connection is plain HTTP without a password, so use a trusted private network."))
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            List {
                Section {
                    robotRows
                } header: {
                    Text(.reachy("Find the robot"))
                }
                Section {
                    // The example is the robot's own name on the network, which is not
                    // a word to translate.
                    TextField(text: $model.typedAddress, prompt: Text(verbatim: "reachy-mini.local")) {
                        Text(.reachy("Address"))
                    }
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(connectToTypedAddress)
                    Button(action: connectToTypedAddress) {
                        progressLabel(.reachy("Connect"), busy: model.picked == .typedAddress)
                    }
                    .disabled(!model.typedAddressIsValid)
                } header: {
                    Text(.reachy("Address"))
                }
            }
            .frame(width: TVMetrics.listWidth)
        }
        .padding(TVMetrics.gutter)
    }

    @ViewBuilder
    private var robotRows: some View {
        if model.robots.isEmpty {
            if model.browser.permissionLooksDenied {
                Text(.reachy("Local Network permission denied"))
            } else {
                Label {
                    Text(.reachy("Searching…"))
                } icon: {
                    ProgressView()
                }
            }
        } else {
            ForEach(model.robots) { service in
                Button {
                    Task { await model.connect(to: service) }
                } label: {
                    // The advert's own name — runtime text, like a robot's name.
                    progressLabel(service.name, busy: model.picked == .service(service.id))
                }
            }
        }
    }

    /// What the last thing the reader asked for came to. The sweep's own attempts are
    /// left out (`TVConnectionModel.picked`); an explicit connect that failed latches
    /// as `.failed`, and only an explicit one does.
    @ViewBuilder
    private var status: some View {
        if model.picked != nil {
            Label {
                Text(.reachy("Connecting…"))
            } icon: {
                ProgressView()
            }
        } else if model.pickFailed {
            Text(.reachy("Robot unreachable"))
                .foregroundStyle(.secondary)
        } else if case let .connecting(.failed(_, message)) = session.phase {
            // ReachyKit's own sentence: it carries the daemon's words, which no
            // catalogue can hold.
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    private func progressLabel(_ title: LocalizedStringResource, busy: Bool) -> some View {
        progressLabel(String(localized: title), busy: busy)
    }

    private func progressLabel(_ title: String, busy: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if busy {
                ProgressView()
            }
        }
    }

    private func connectToTypedAddress() {
        guard model.typedAddressIsValid else { return }
        Task { await model.connectToTypedAddress() }
    }
}

/// The handshake worked and the robot's backend is down. Starting it moves nothing:
/// `startBackend()` asks the daemon not to wake the robot, as the phone's gate does.
private struct TVBackendStoppedView: View {
    let session: RobotSession
    let identity: RobotIdentity

    var body: some View {
        TVDecisionLayout(identity: identity) {
            if session.powerTransition == .startingBackend {
                Label {
                    Text(.reachy("Starting the motors and camera… this can take a minute"))
                } icon: {
                    ProgressView()
                }
            } else {
                Text(.reachy("Motors and camera are off"))
            }
        } actions: {
            Button {
                Task { await session.startBackend() }
            } label: {
                Text(.reachy("Start the motors and camera"))
            }
            .disabled(session.powerTransition != nil)
            Button(role: .cancel) {
                session.disconnect()
            } label: {
                Text(.reachy("Cancel"))
            }
        }
    }
}

/// The daemon is older than this app can talk to (ADR 0001). The TV sends it nothing
/// and offers no update of its own: the phone's app is where a robot is updated.
private struct TVDaemonUpdateView: View {
    let session: RobotSession
    let identity: RobotIdentity
    let requirement: DaemonUpdateRequirement

    var body: some View {
        TVDecisionLayout(identity: identity) {
            Text(.reachy("This robot needs a software update"))
            if requirement.canSelfUpdate {
                Text(.reachy("Update it with Hey Reachy on an iPhone, an iPad or a Mac."))
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    .reachy(
                        // swiftlint:disable:next line_length
                        "This robot cannot update itself over the network. Connect it to the official desktop app over USB to update it."
                    )
                )
                .foregroundStyle(.secondary)
            }
        } actions: {
            Button {
                session.disconnect()
            } label: {
                Text(.reachy("Disconnect"))
            }
        }
    }
}

/// A robot's name over one or two sentences and the buttons that answer them.
private struct TVDecisionLayout<Message: View, Actions: View>: View {
    let identity: RobotIdentity
    @ViewBuilder let message: Message
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: TVMetrics.group) {
            Text(verbatim: identity.name ?? Bundle.main.displayName)
                .font(Typography.screenTitle.bold())
            VStack(alignment: .leading, spacing: Space.lg) {
                message
            }
            .font(Typography.rowTitle)
            HStack(spacing: TVMetrics.group) {
                actions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(TVMetrics.gutter)
    }
}
