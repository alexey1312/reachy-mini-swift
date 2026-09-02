import ReachyDesign
import ReachyKit
import SwiftUI

/// The one command that destroys something the robot cannot get back.
///
/// Four gates, deliberately unalike — three copies of the same alert train a thumb to
/// dismiss all three. One is a claim to have understood, one is a value you have to
/// actually possess, one is a wait, and the last is a dialog that names the outcome.
struct BLESoftwareResetScreen: View {
    let model: BLEConsoleModel
    let script: BLERecoveryScript

    @State private var acknowledged = false
    @State private var typedID = ""
    @State private var code = ""
    @State private var countdown: Int?
    @State private var confirming = false
    @State private var dispatched = false
    @State private var stillAnswering: Bool?
    @Environment(\.reachyPreviewMode) private var previewMode

    /// Long enough to interrupt a run of taps, short enough not to become its own ritual.
    private static let arming = 5

    /// The gates are `@State` rather than model state, so a preview of a half-filled or
    /// already-dispatched screen has to be handed them.
    init(
        model: BLEConsoleModel,
        script: BLERecoveryScript,
        acknowledged: Bool = false,
        typedID: String = "",
        code: String = "",
        dispatched: Bool = false,
        stillAnswering: Bool? = nil
    ) {
        self.model = model
        self.script = script
        _acknowledged = State(initialValue: acknowledged)
        _typedID = State(initialValue: typedID)
        _code = State(initialValue: code)
        _dispatched = State(initialValue: dispatched)
        _stillAnswering = State(initialValue: stillAnswering)
    }

    var body: some View {
        Form {
            if dispatched {
                restoring
            } else {
                consequences
                gates
            }
        }
        .formStyle(.grouped)
        .navigationTitle(script.name)
        .onChange(of: gatesPassed, initial: true) { _, passed in
            countdown = passed ? Self.arming : nil
        }
        .task(id: countdown) {
            guard let value = countdown, value > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            countdown = value - 1
        }
        .confirmationDialog(
            .reachy("Erase the robot's software?"),
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(.reachy("Erase and restore"), role: .destructive) {
                Task { await dispatch() }
            }
        } message: {
            Text(script.summary)
        }
    }

    private var consequences: some View {
        Section(.reachy("What this does")) {
            bullet(String(localized: .reachy("Deletes the robot's Python environments outright.")))
            bullet(String(localized: .reachy("Copies the factory set back from the robot's own restore directory.")))
            bullet(String(localized: .reachy("Every app you installed, and everything those apps stored, is gone.")))
            bullet(String(localized: .reachy("It takes about five minutes. Do not power the robot off during it.")))
        }
    }

    @ViewBuilder
    private var gates: some View {
        Section {
            Toggle(.reachy("I understand every installed app will be erased"), isOn: $acknowledged)
        }
        Section {
            TextField(.reachy("Hardware ID"), text: $typedID)
                .font(Typography.console)
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
        } header: {
            Text(.reachy("Confirm the robot"))
        } footer: {
            if let hardwareID = model.hardwareID {
                Text(.reachy("Type \(hardwareID) — this robot's id, shown so you are erasing the one in front of you."))
                    .font(Typography.consoleLine)
            } else {
                Text(.reachy("This robot did not report a hardware id, so it cannot be confirmed. Do not continue."))
            }
        }
        Section {
            SecureField(.reachy("Robot's code"), text: $code)
                .font(Typography.console)
        } header: {
            Text(.reachy("Confirm it is you"))
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "Sent again the instant before the command goes out, so a session opened earlier for something harmless cannot carry this through with it."
                )
            )
        }
        Section {
            Button(role: .destructive) {
                confirming = true
            } label: {
                if let countdown, countdown > 0 {
                    Text(.reachy("Erase and restore in \(countdown)…"))
                } else {
                    Text(.reachy("Erase and restore"))
                }
            }
            .disabled(!gatesPassed || (countdown ?? Self.arming) > 0)
            if let error = model.errorMessage {
                Text(error).font(Typography.detail).foregroundStyle(Tone.danger.style)
            }
        }
    }

    private var restoring: some View {
        Section(.reachy("Restoring")) {
            // Optical: the severity glyph sits beside the script's name as one row.
            // swiftlint:disable:next raw_spacing
            HStack(spacing: 10) {
                ProgressView()
                Text(.reachy("This takes about five minutes. Leave the robot powered on."))
            }
            LabeledContent(.reachy("Bluetooth")) {
                switch stillAnswering {
                case true: Text(.reachy("answering")).foregroundStyle(Tone.success.style)
                case false: Text(.reachy("no answer")).foregroundStyle(Tone.warning.style)
                case nil: ProgressView()
                }
            }
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "The Bluetooth service is a separate unit and stays up throughout, so this only says the robot is still there. Progress shows up in the journal when the daemon comes back."
                )
            )
            .font(Typography.footer)
            .foregroundStyle(.secondary)
        }
        .task {
            guard !previewMode else { return }
            while !Task.isCancelled {
                stillAnswering = await model.isAnswering()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var gatesPassed: Bool {
        acknowledged && matchesHardwareID && code.count == BLEPinSession.length
    }

    /// Case and stray whitespace forgiven; the point is possession of the value, not
    /// transcription accuracy.
    private var matchesHardwareID: Bool {
        guard let hardwareID = model.hardwareID else { return false }
        return typedID.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(hardwareID) == .orderedSame
    }

    private func dispatch() async {
        let sent = await model.runGuarded(script, code: code)
        code = ""
        dispatched = sent
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "circle.fill")
            .labelStyle(BulletLabelStyle())
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            configuration.icon
                // Optical: a bullet dot rather than text — 5 pt is the dot's diameter.
                // swiftlint:disable:next raw_font
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}
