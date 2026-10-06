import ReachyDesign
import ReachyKit
import SwiftUI

/// Names the robot over Bluetooth, before it has a network to be named on.
///
/// Optional, and it says so: the robot keeps the name it has, and Settings renames it
/// later. On a 1.9.x robot the command is not there at all, and the step turns into
/// that sentence and a way on.
struct OnboardingNameStep: View {
    let model: OnboardingModel

    @FocusState private var focused: Bool

    var body: some View {
        OnboardingStepScaffold(
            title: String(localized: .reachy("Name your robot")),
            message: String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "The name shows in this app, on your network and for remote access. You can change it later in Settings."
                )
            )
        ) {
            Section {
                TextField(.reachy("Name"), text: Binding(get: { model.nameInput }, set: { model.nameInput = $0 }))
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(submit)
                    .disabled(model.nameIsUnsupported)
            } footer: {
                if model.nameIsUnsupported {
                    Label(
                        .reachy(
                            // swiftlint:disable:next line_length
                            "This robot's software is too old to be named over Bluetooth. Rename it in Settings once it is on your network."
                        ),
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(Tone.warning.style)
                }
            }
            if let message = model.errorMessage {
                Section {
                    ReachyErrorRow(message)
                }
            }
        } actions: {
            if model.nameIsUnsupported {
                ReachyActionButton(.reachy("Continue"), fullWidth: true) {
                    Task { await model.skipName() }
                }
            } else {
                ReachyActionButton(.reachy("Use this name"), fullWidth: true) {
                    submit()
                }
                .disabled(!model.canSubmitName)
                ReachyActionButton(.reachy("Skip"), emphasis: .quiet, fullWidth: true) {
                    Task { await model.skipName() }
                }
                .disabled(model.isBusy)
            }
            OnboardingBackButton(model: model)
        }
        .onAppear { focused = !model.nameIsUnsupported }
    }

    private func submit() {
        guard model.canSubmitName else { return }
        Task { await model.submitName() }
    }
}
