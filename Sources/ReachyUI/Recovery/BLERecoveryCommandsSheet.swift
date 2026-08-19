import ReachyDesign
import ReachyKit
import SwiftUI

/// The scripts the robot actually has, grouped by what they cost.
///
/// The destructive one is not in the list. It sits behind a collapsed group that leads to
/// its own screen, because a row a thumb can reach by accident is the wrong place for
/// something that erases the robot's software.
struct BLERecoveryCommandsSheet: View {
    let model: BLEConsoleModel

    @State private var confirming: BLERecoveryScript?

    var body: some View {
        Form {
            // The list is readable without the code — `…cdef6` is a plain characteristic —
            // so it is shown either way. Asking for a code in front of an empty page gives
            // the user no way to judge whether it is worth fetching the robot's base.
            if isLocked {
                unlock
            }
            commands
                .disabled(isLocked)
        }
        .formStyle(.grouped)
        .navigationTitle(.reachy("Commands"))
        .confirmationDialog(
            confirming?.name ?? "",
            isPresented: Binding(get: { confirming != nil }, set: {
                if !$0 {
                    confirming = nil
                }
            }),
            presenting: confirming
        ) { script in
            Button(.reachy("Run \(script.name)"), role: .destructive) {
                Task { await model.run(script) }
            }
        } message: { script in
            Text(script.summary)
        }
    }

    private var isLocked: Bool {
        model.stage != .unlocked
    }

    private var unlock: some View {
        Section {
            TextField(
                .reachy("Five-character code"),
                text: Binding(get: { model.pinInput }, set: { model.pinInput = $0 })
            )
            .font(Typography.console)
            .autocorrectionDisabled()
            #if os(iOS)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
            #endif
                .onSubmit(submit)
            Button(.reachy("Unlock the robot"), action: submit)
                .reachyButton(.prominent)
                .frame(maxWidth: .infinity)
                .disabled(!model.canSubmitPIN)
            if let error = model.errorMessage {
                Text(error).font(Typography.detail).foregroundStyle(Tone.danger.style)
            }
        } header: {
            Text(.reachy("Code"))
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "The last five characters of the serial number printed on the robot. Capitals matter, and it is not always digits. Running any script clears the robot's session, so the code is needed again each time — that is the robot's rule, not this app's."
                )
            )
        }
    }

    private func submit() {
        guard model.canSubmitPIN else { return }
        Task { await model.submitPIN() }
    }

    @ViewBuilder
    private var commands: some View {
        let ordinary = model.scripts.filter { $0.severity != .destructive }
        let destructive = model.scripts.filter { $0.severity == .destructive }

        Section {
            if ordinary.isEmpty {
                Text(.reachy("This robot reports no recovery scripts."))
                    .foregroundStyle(.secondary)
            }
            ForEach(ordinary) { script in
                Button {
                    confirming = script
                } label: {
                    BLERecoveryScriptRow(script: script)
                }
            }
        } header: {
            Text(.reachy("Commands"))
        } footer: {
            Text(isLocked
                ? String(localized: .reachy("Enter the code above to run any of these."))
                : String(
                    localized: .reachy(
                        // swiftlint:disable:next line_length
                        "A script answers nothing — the robot's handler crashes encoding its own reply. Watch the journal for what happened."
                    )
                ))
        }

        if !destructive.isEmpty {
            Section {
                DisclosureGroup(String(localized: .reachy("Destructive recovery"))) {
                    ForEach(destructive) { script in
                        NavigationLink {
                            BLESoftwareResetScreen(model: model, script: script)
                        } label: {
                            BLERecoveryScriptRow(script: script)
                        }
                    }
                }
            }
        }
    }
}

struct BLERecoveryScriptRow: View {
    let script: BLERecoveryScript

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(script.name)
                    .font(Typography.console)
                Text(script.summary)
                    .font(Typography.footer)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var icon: String {
        switch script.severity {
        case .routine: "arrow.clockwise"
        case .disruptive: "exclamationmark.triangle"
        case .destructive: "trash"
        }
    }

    private var tint: Color {
        switch script.severity {
        case .routine: .secondary
        case .disruptive: .orange
        case .destructive: .red
        }
    }
}
