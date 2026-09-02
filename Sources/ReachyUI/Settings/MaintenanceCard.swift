import ReachyDesign
import ReachyKit
import SwiftUI

/// Freeing the robot's disk, and the one way to uninstall every app at once.
///
/// Both routes live at the app root under `--wireless-version`, so this whole
/// section is absent on a Lite robot and over the relay — `canPerformMaintenance`
/// answers for both.
struct MaintenanceCard: View {
    let session: RobotSession

    @State private var model: MaintenanceModel
    @Environment(\.reachyPreviewMode) private var previewMode

    /// `@MainActor` because `MaintenanceModel` is: a defaulted argument whose
    /// value is main-actor-isolated compiles in the SwiftPM targets and not in
    /// the `Apps/` ones, where it is evaluated nonisolated.
    @MainActor
    init(session: RobotSession, model: MaintenanceModel? = nil) {
        self.session = session
        _model = State(initialValue: model ?? MaintenanceModel())
    }

    var body: some View {
        Section {
            action(
                .clearHuggingFaceCache,
                description: .reachy("Model weights the robot has downloaded. An app fetches what it needs again."),
                button: .reachy("Clear Hugging Face cache"),
                systemImage: "arrow.down.circle.dotted"
            )
            action(
                .resetApps,
                description: resetDescription,
                button: .reachy("Uninstall all apps"),
                systemImage: "trash"
            )
            if let lastError = model.lastError {
                Text(lastError)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
            }
        } header: {
            Text(.reachy("Maintenance"))
        } footer: {
            Text(.reachy("Neither can be undone from here."))
        }
        .confirmationDialog(
            confirmation.title,
            isPresented: isConfirming,
            titleVisibility: .visible
        ) {
            if let pending = model.confirming {
                Button(confirmation.confirm, role: .destructive) {
                    Task { await model.perform(pending, session: session) }
                }
            }
        } message: {
            Text(confirmation.message)
        }
        // Guarded on preview mode the way `WiFiSettingsCard` is: the effect runs
        // unconditionally, and a snapshot must not depend on a request. Previews
        // inject the list instead.
        .task {
            guard !previewMode else { return }
            await model.loadInstalled(session: session)
        }
    }

    /// The robot's own dashboard puts the sentence above the button, and it is
    /// the right way round for something irreversible: the reader meets what it
    /// does before they meet the thing that does it.
    private func action(
        _ action: MaintenanceModel.Action,
        description: LocalizedStringResource,
        button: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(description)
                .font(Typography.status)
                .foregroundStyle(.secondary)
            HStack {
                Button(role: .destructive) {
                    model.confirming = action
                } label: {
                    Label(button, systemImage: systemImage)
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy || isBlocked(action))
                Spacer()
                trailing(for: action)
            }
        }
    }

    @ViewBuilder
    private func trailing(for action: MaintenanceModel.Action) -> some View {
        if model.running == action {
            ProgressView().controlSize(.small)
        } else if model.finished == action {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Tone.success.style)
                .accessibilityLabel(.reachy("Done"))
        }
    }

    /// Names the app in the way, rather than leaving a greyed-out button with no
    /// explanation — the reader would have no idea what to do about it.
    ///
    /// The settled description names **settings** as well as apps, because that is
    /// the part reinstalling does not undo: each app's `.env`,
    /// `startup_settings.json` and `user_personalities/` live inside
    /// `site-packages/<package>/`, so `rmtree` takes the credentials with the code.
    /// It said only "every installed app, and the Python environment they share",
    /// which is true and reads as recoverable.
    private var resetDescription: LocalizedStringResource {
        if let blocking = model.blockingApp(session) {
            .reachy("Stop \(blocking.title) first — uninstalling deletes the environment it is running in.")
        } else {
            .reachy("Every installed app, the Python environment they share, and each app's own settings.")
        }
    }

    // A region disable rather than `disable:next`, and it is forced: a sentence is
    // one key — splitting it across `+` makes two fragments a translator cannot
    // reorder — so the literal is over the column limit, and swiftformat rewraps it
    // onto a line of its own, which leaves a `disable:next` pointing at the `return`
    // instead of at the literal. The two rules undid each other on every
    // `mise run format`. It sits above the doc comment because between the two it
    // orphans it (`orphaned_doc_comment`).
    // swiftlint:disable line_length

    /// Names the apps one by one when the list is in hand, and falls back to "every
    /// app" when it is not — an unread list must not read as an empty robot.
    ///
    /// Both spellings name **settings and credentials**, because that is the part
    /// reinstalling does not undo and the part the old wording left out.
    private var resetMessage: LocalizedStringResource {
        if let summary = model.installedSummary {
            return .reachy(
                "\(summary) are deleted, with the Python environment they share. Each app's own settings and credentials go too, and reinstalling does not bring those back."
            )
        }
        return .reachy(
            "Every app is deleted, with the Python environment they share. Each app's own settings and credentials go too, and reinstalling does not bring those back."
        )
    }

    // swiftlint:enable line_length

    private func isBlocked(_ action: MaintenanceModel.Action) -> Bool {
        action == .resetApps && model.blockingApp(session) != nil
    }

    private var isConfirming: Binding<Bool> {
        Binding(
            get: { model.confirming != nil },
            set: { presented in
                if !presented {
                    model.confirming = nil
                }
            }
        )
    }

    private var confirmation: Confirmation {
        switch model.confirming {
        // Named one by one when the list is in hand. Nothing on the robot reports
        // what a deleted venv used to hold, so this dialog is the last place the
        // names appear — and seeing them is what makes the count mean something.
        case .resetApps:
            Confirmation(
                title: .reachy("Remove every app?"),
                message: resetMessage,
                confirm: .reachy("Uninstall all")
            )
        // `.clearHuggingFaceCache` and nil share this arm: the dialog is only on
        // screen while `confirming` is set, and the property has to answer anyway.
        // Spelled out rather than `default`, so a third action is a compile error
        // here instead of silently inheriting this one's wording.
        case .clearHuggingFaceCache, .none:
            Confirmation(
                title: .reachy("Clear cached models?"),
                // swiftlint:disable:next line_length
                message: .reachy(
                    "Downloaded model weights are deleted. The robot downloads them again when an app needs them."
                ),
                confirm: .reachy("Clear cache")
            )
        }
    }
}
