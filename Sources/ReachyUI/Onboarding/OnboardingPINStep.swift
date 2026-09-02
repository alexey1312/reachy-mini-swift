import ReachyDesign
import ReachyKit
import SwiftUI

/// Unlocks the robot's 300-second session with the code printed on its base.
///
/// The wrong-code throttle is the robot's, not this screen's: it is global to the robot
/// and survives a reconnect, so during a lockout there is nothing to do but wait it out
/// in plain sight.
struct OnboardingPINStep: View {
    let model: OnboardingModel

    @FocusState private var focused: Bool

    var body: some View {
        OnboardingStepScaffold(
            title: String(localized: .reachy("Enter the robot's code")),
            message: String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "The last five characters of the serial number printed on the robot. Capitals matter, and it is not always digits."
                )
            )
        ) {
            Section {
                TextField(.reachy("Code"), text: Binding(get: { model.pinInput }, set: { model.pinInput = $0 }))
                    // Optical: a code field wants the title size in monospace; one consumer, so not a Typography role yet.
                    // swiftlint:disable:next raw_font
                    .font(.title3.monospaced())
                    .autocorrectionDisabled()
                    .focused($focused)
                #if os(iOS)
                    // Deliberately not `.numberPad`: the code is the tail of a serial number
                    // and can contain letters, and autocapitalising it would break a robot
                    // whose code is lower-case.
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                #endif
                    .onChange(of: model.pinInput) { _, value in
                        if value.count > BLEPinSession.length {
                            model.pinInput = String(value.prefix(BLEPinSession.length))
                        }
                    }
                    .onSubmit(submit)
                    .disabled(model.lockoutSeconds != nil)
            } footer: {
                footer
            }
            if model.lockoutSeconds == nil, let message = model.errorMessage {
                Section {
                    ReachyErrorRow(message)
                }
            }
        } actions: {
            ReachyActionButton(.reachy("Unlock"), fullWidth: true) {
                submit()
            }
            .disabled(!model.canSubmitPIN)
            OnboardingBackButton(model: model)
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var footer: some View {
        if let seconds = model.lockoutSeconds {
            Label(
                .reachy(
                    // swiftlint:disable:next line_length
                    "Too many wrong codes. The robot will accept another in \(seconds) s — reconnecting does not clear this."
                ),
                systemImage: "clock"
            )
            .foregroundStyle(Tone.warning.style)
        } else if model.attemptsBeforeLockout < BLEPinSession.freeAttempts {
            Text(.reachy("\(model.attemptsBeforeLockout) attempts left before the robot starts making you wait."))
        }
    }

    private func submit() {
        guard model.canSubmitPIN else { return }
        Task { await model.submitPIN() }
    }
}
