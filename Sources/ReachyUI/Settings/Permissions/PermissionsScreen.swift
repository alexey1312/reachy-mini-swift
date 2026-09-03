import ReachyDesign
import ReachyKit
import SwiftUI

/// Everything the app needs the system's permission for, what it has, and how to give
/// it the rest.
///
/// It exists because a refusal used to be reported only where it bit — and in one case
/// (the microphone) not at all — so there was no answer to "what have I actually said
/// yes to?". Reachable from Settings and from the connection screen both: the Settings
/// tab only exists once a robot is connected, and two of these three permissions are
/// what connecting needs.
///
/// **Opening it must never raise a prompt.** Every state on screen is read from a
/// source that can answer without asking; each way to *ask* is behind a button. That is
/// also why the Bluetooth row is not a plain toggle — see `requestBluetooth`.
///
/// No `NavigationStack` of its own: Settings pushes it, the connection screen sheets it.
struct PermissionsScreen: View {
    /// Whether a live connection has already settled the local-network question. The
    /// probe can only confirm a grant by finding something, so a session that is
    /// already talking to a robot over the LAN is the better evidence where it exists.
    private let localNetworkProvenByConnection: Bool

    @State private var model: PermissionsModel?
    @Environment(\.reachyPreviewMode) private var previewMode

    /// The model resolves to `nil` here and is built in the body: a default argument is
    /// evaluated in a nonisolated context, and this one is `@MainActor`.
    init(model: PermissionsModel? = nil, localNetworkProvenByConnection: Bool = false) {
        _model = State(initialValue: model)
        self.localNetworkProvenByConnection = localNetworkProvenByConnection
    }

    var body: some View {
        Form {
            if let model {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    section(for: kind, model: model)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(.reachy("Privacy"))
        .onAppear(perform: appeared)
    }

    private func appeared() {
        let resolved = model ?? PermissionsModel()
        model = resolved
        // The effect runs unconditionally, which is exactly where this target's
        // `AGENTS.md` says the mode check belongs: an injected model is already in its
        // end state, and refreshing would overwrite it with whatever the simulator
        // running the snapshot happens to have granted.
        guard !previewMode else { return }
        resolved.refresh()
        // In a `Task` off `onAppear` rather than in a `.task` of its own, so there is
        // no question of which runs first: `model` is resolved on the line above, and
        // a second effect would have to resolve it again or race with this one.
        Task { await resolved.refreshNotifications() }
        if localNetworkProvenByConnection {
            resolved.noteLocalNetworkProvenByConnection()
        }
    }

    /// No `header:`. The title is already in the row, next to the glyph that carries
    /// it, and repeating it above would say "Microphone" twice on one card. That also
    /// sidesteps the overload trap this target's `AGENTS.md` records: there is no
    /// title-plus-footer `Section`, and `Section("X") { } footer: { }` fails with a
    /// misleading message about `Content`.
    private func section(for kind: PermissionKind, model: PermissionsModel) -> some View {
        Section {
            LabeledContent {
                kind.label(model[kind])
            } label: {
                Label(kind.title, systemImage: kind.symbol)
            }
            action(for: kind, model: model)
        } footer: {
            footer(for: kind, model: model)
        }
    }

    @ViewBuilder
    private func action(for kind: PermissionKind, model: PermissionsModel) -> some View {
        if model.busy == kind {
            HStack(spacing: Space.sm) {
                ProgressView().controlSize(.small)
                Text(.reachy("Asking…")).foregroundStyle(Tone.quiet.style)
            }
        } else if model[kind].isBlocking {
            // Restricted lands here too, and deliberately: the caption already says the
            // toggle is not the user's to move, and Settings is still where they would
            // go to see that for themselves.
            PrivacySettingsButton(pane: kind.pane)
        } else if model[kind] == .undetermined {
            Button(prompt(for: kind)) {
                Task { await request(kind, model: model) }
            }
        }
    }

    private func prompt(for kind: PermissionKind) -> LocalizedStringResource {
        // "Check" rather than "Allow": there is no way to read the local network's
        // status without also asking for it, so the button cannot honestly promise
        // which of the two it is about to do.
        kind == .localNetwork ? .reachy("Check") : .reachy("Allow")
    }

    private func request(_ kind: PermissionKind, model: PermissionsModel) async {
        switch kind {
        case .bluetooth: await model.requestBluetooth()
        case .localNetwork: await model.checkLocalNetwork()
        case .microphone: await model.requestMicrophone()
        case .notifications: await model.requestNotifications()
        }
    }

    private func footer(for kind: PermissionKind, model: PermissionsModel) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(kind.why)
            detail(for: kind, model: model)
                .foregroundStyle(Tone.quiet.style)
        }
    }

    /// A `@ViewBuilder` rather than an optional `LocalizedStringResource`: returning one
    /// would put `.reachy(…)` in a position whose contextual type is an `Optional`, and
    /// implicit member lookup through `Optional` is exactly the inference this codebase
    /// should not be betting a build on.
    @ViewBuilder
    private func detail(for kind: PermissionKind, model: PermissionsModel) -> some View {
        switch kind {
        case .bluetooth:
            bluetoothDetail(model)
        case .localNetwork:
            if model[kind] == .undetermined {
                // Says out loud what `LocalNetworkProbe` cannot: a granted permission on
                // a Wi-Fi with no robot on it also lands here, so "unknown" is not the
                // same as "refused" and the copy must not let it read that way.
                Text(.reachy("Checking looks for a robot on this Wi-Fi, and asks for permission if it has not yet."))
            }
        case .microphone, .notifications:
            EmptyView()
        }
    }

    /// Authorization and the radio are different questions, and only the second one can
    /// say "switched off". It is unknown until something builds a central, so this line
    /// appears after the Allow button has been used and not before.
    @ViewBuilder
    private func bluetoothDetail(_ model: PermissionsModel) -> some View {
        if let availability = model.bluetoothAvailability {
            switch availability {
            case .poweredOff:
                Text(.reachy("Bluetooth is switched off. Turn it on in Control Centre or Settings."))
            // Verbatim the onboarding scan step's key, period and all: the catalogue
            // derives a Swift symbol per key, and two that differ only in punctuation
            // are a hard `xcstringstool` error rather than a warning.
            case .unsupported:
                Text(.reachy("This device has no Bluetooth"))
            case .ready, .unauthorized, .unknown:
                EmptyView()
            }
        }
    }
}
