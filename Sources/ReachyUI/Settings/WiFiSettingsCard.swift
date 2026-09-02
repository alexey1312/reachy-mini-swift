import ReachyDesign
import ReachyKit
import SwiftUI

/// What the robot is on, what it remembers, why the last attempt failed — and the way
/// to move it somewhere else.
///
/// Moving it is the same handover the Bluetooth flow does, over the connection this
/// session already has: the robot answers and then takes the link down, so the sheet
/// hands back to discovery rather than waiting.
struct WiFiSettingsCard: View {
    let session: RobotSession

    @State private var model: WiFiSettingsModel
    /// The dialog and the sheet are the card's own business: nothing outside the view
    /// reads them and no test can reach them, so they stay here.
    @State private var confirmingForgetAll = false
    @State private var confirmingForget: String?
    @State private var joining = false
    @Environment(\.reachyPreviewMode) private var previewMode

    /// `@MainActor` because `WiFiSettingsModel` is: a defaulted argument whose value
    /// is main-actor-isolated compiles in the SwiftPM targets and not in the `Apps/`
    /// ones, where it is evaluated nonisolated.
    @MainActor
    init(session: RobotSession, model: WiFiSettingsModel? = nil) {
        self.session = session
        _model = State(initialValue: model ?? WiFiSettingsModel())
    }

    var body: some View {
        Section {
            LabeledContent(.reachy("Mode"), value: model.modeText)
            if let connected = model.status?.connected {
                LabeledContent(.reachy("Network"), value: connected)
            }
            if let joinError = model.joinError {
                // Optical: the two lines of the status row read as one.
                // swiftlint:disable:next raw_spacing
                VStack(alignment: .leading, spacing: 6) {
                    Text(joinError)
                        .font(Typography.detail)
                        .foregroundStyle(Tone.warning.style)
                    Button(.reachy("Clear this error")) {
                        Task { await model.clearError(session: session) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button(.reachy("Change network")) { joining = true }
                .disabled(model.busy)
            ForEach(model.status?.known ?? [], id: \.self) { network in
                LabeledContent(network) {
                    Button(.reachy("Forget"), role: .destructive) {
                        confirmingForget = network
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.busy)
                }
            }
            if model.offersForgetAll {
                Button(.reachy("Forget all"), role: .destructive) {
                    confirmingForgetAll = true
                }
                .buttonStyle(.borderless)
                .disabled(model.busy)
            }
            if let loadFailure = model.loadFailure {
                Text(loadFailure)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
            }
        } header: {
            Text(.reachy("Network"))
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "Forgetting the network the robot is on takes it off this network at the next restart. The robot's own hotspot cannot be forgotten."
                )
            )
        }
        .task {
            guard !previewMode else { return }
            await model.load(session: session)
        }
        .sheet(isPresented: $joining) {
            NavigationStack {
                WiFiJoinSheet(session: session) { joining = false }
            }
            .reachySheet()
        }
        .confirmationDialog(
            .reachy("Forget every saved network?"),
            isPresented: $confirmingForgetAll,
            titleVisibility: .visible
        ) {
            Button(.reachy("Forget all"), role: .destructive) {
                Task { await model.forgetAll(session: session) }
            }
        } message: {
            Text(.reachy("The robot falls back to its own hotspot at the next restart."))
        }
        .confirmationDialog(
            forgetConfirmation.title,
            isPresented: Binding(get: { confirmingForget != nil }, set: {
                if !$0 {
                    confirmingForget = nil
                }
            }),
            titleVisibility: .visible
        ) {
            if let network = confirmingForget {
                Button(forgetConfirmation.confirm, role: .destructive) {
                    Task { await model.forget(network, session: session) }
                }
            }
        } message: {
            Text(forgetConfirmation.message)
        }
    }

    /// Built off whichever row asked. With none asking the dialog is not on screen,
    /// and the placeholder is never read.
    private var forgetConfirmation: Confirmation {
        WiFiSettingsModel.forgetConfirmation(for: confirmingForget ?? "")
    }
}
