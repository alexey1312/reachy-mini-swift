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
            TextField(.reachy("Code"), text: Binding(get: { model.pinInput }, set: { model.pinInput = $0 }))
                .textFieldStyle(.roundedBorder)
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

            if let seconds = model.lockoutSeconds {
                Label(
                    .reachy(
                        // swiftlint:disable:next line_length
                        "Too many wrong codes. The robot will accept another in \(seconds) s — reconnecting does not clear this."
                    ),
                    systemImage: "clock"
                )
                .font(Typography.detail)
                .foregroundStyle(Tone.warning.style)
                .fixedSize(horizontal: false, vertical: true)
            } else if model.attemptsBeforeLockout < BLEPinSession.freeAttempts {
                OnboardingErrorText(message: model.errorMessage)
                Text(.reachy("\(model.attemptsBeforeLockout) attempts left before the robot starts making you wait."))
                    .font(Typography.footer)
                    .foregroundStyle(.secondary)
            } else {
                OnboardingErrorText(message: model.errorMessage)
            }
        } actions: {
            Button(.reachy("Unlock")) {
                submit()
            }
            .reachyButton(.prominent)
            .frame(maxWidth: .infinity)
            .disabled(!model.canSubmitPIN)
            OnboardingBackButton(model: model)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard model.canSubmitPIN else { return }
        Task { await model.submitPIN() }
    }
}
