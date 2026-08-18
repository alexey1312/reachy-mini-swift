import ReachyDesign
import ReachyKit
import ReachySSH
import SwiftUI

/// Everything about the connected robot that is a setting rather than a control.
///
/// Audio used to be a section of `RobotScreen` and a sheet of its own on the Live
/// tab; both now open this, so there is one place to look.
///
/// The Hugging Face account is deliberately *not* here any more. It outlives every
/// connection and is needed before one — signing in is what makes the remote robot
/// list exist — so it sits in the navigation bar instead, robot or no robot.
/// Linking a robot to that account went with it: both halves of the custody story
/// belong on one screen, and splitting them was how "signing out does not unlink"
/// stopped being visible.
struct SettingsScreen: View {
    let session: RobotSession

    @State private var nameDraft = ""
    @State private var isRenaming = false
    @State private var renameError: String?
    @FocusState private var nameFocused: Bool
    private var identity: RobotIdentity? {
        switch session.phase {
        case let .connected(identity), let .unreachable(identity): identity
        default: nil
        }
    }

    var body: some View {
        Form {
            robotSection
            if session.isBackendRunning {
                AudioSettingsSection(session: session)
            }
            if session.supportsWirelessFeatures {
                SystemUpdateCard(session: session)
            }
            AppearanceSection()
            privacySection
            AdvancedSettingsSection(session: session)
        }
        .formStyle(.grouped)
        .navigationTitle(.reachy("Settings"))
        .onAppear { nameDraft = identity?.name ?? "" }
    }

    /// Above Advanced rather than in it: everything in that group is about a robot
    /// that is already answering, and this needs no robot at all. The same screen is
    /// reachable from the connection gate, which is where someone whose permissions
    /// are the reason they cannot get this far will find it.
    ///
    /// A LAN link is proof the local network was granted — the daemon cannot be
    /// reached without it — and a relay session is proof of nothing, which is the
    /// case worth being able to see.
    private var privacySection: some View {
        Section {
            NavigationLink {
                PermissionsScreen(localNetworkProvenByConnection: isConnectedOverLAN)
            } label: {
                Label(.reachy("Privacy"), systemImage: "hand.raised")
            }
        }
    }

    private var isConnectedOverLAN: Bool {
        switch session.link {
        case .lan: true
        case .none, .remote: false
        }
    }

    private var robotSection: some View {
        Section {
            HStack {
                TextField(.reachy("Name"), text: $nameDraft)
                    .focused($nameFocused)
                    .autocorrectionDisabled()
                    .onSubmit { rename() }
                    .disabled(!nameField.isEditable)
                    // A `Form` row does not grey a disabled `TextField` out on its own,
                    // and the footer alone reads as a note rather than as a locked field.
                    .foregroundStyle(nameField.isEditable ? Color.primary : Color.secondary)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                if isRenaming {
                    ProgressView().controlSize(.small)
                } else if canRename {
                    Button(.reachy("Save"), action: rename)
                        .buttonStyle(.borderless)
                }
            }
            if let renameError {
                Text(renameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            LabeledContent(.reachy("Daemon"), value: identity?.daemonVersion ?? "—")
            LabeledContent(.reachy("Connection"), value: ConnectionLinkCaption.text(for: session.link))
            if let hardwareID = identity?.hardwareID {
                LabeledContent(.reachy("Hardware ID"), value: hardwareID)
                    .font(.body.monospaced())
            }
        } header: {
            Text(.reachy("Robot"))
        } footer: {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(nameField.footer)
                absentSettingsNote
            }
        }
    }

    /// Why this screen is shorter on a Lite robot and on a simulator.
    ///
    /// It sits here rather than on the Robot tab because this is the screen the
    /// cards are missing *from*: `supportsWirelessFeatures` drops `SystemUpdateCard`
    /// a few lines up, and `canPerformMaintenance` drops `MaintenanceCard` inside
    /// Advanced. Both are correct — neither route is mounted without
    /// `--wireless-version` — and both used to be silent, which is
    /// `MaintenanceCard`'s own rule applied to a whole screen: an absence with no
    /// reason attached tells the reader nothing to act on.
    ///
    /// A Wireless robot and a relayed session get nothing, so their references do
    /// not move for a sentence that does not apply to them.
    @ViewBuilder
    private var absentSettingsNote: some View {
        if let flavour = session.flavour, let note = DaemonFlavourCaption.absentSettings(for: flavour) {
            Text(note)
        }
    }

    private var nameField: RobotNameField {
        RobotNameField(supportsRename: session.supportsRename, daemonVersion: identity?.daemonVersion)
    }

    private var canRename: Bool {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return nameField.isEditable && !trimmed.isEmpty && trimmed != identity?.name && !isRenaming
    }

    private func rename() {
        guard canRename else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        nameFocused = false
        isRenaming = true
        renameError = nil
        Task {
            defer { isRenaming = false }
            do {
                // The daemon may store something other than what was sent, so the
                // field follows what came back rather than what was typed.
                nameDraft = try await session.rename(to: name)
            } catch {
                renameError.recordDaemonFailure(error)
                nameDraft = identity?.name ?? ""
            }
        }
    }
}
