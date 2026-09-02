import ReachyDesign
import ReachyKit
import SwiftUI

/// Chooses the network and takes the password.
///
/// The rows are `NetworkCredentialsFields`, shared with the Wi-Fi sheet; what is this
/// step's own is the footer, which says why a network can be missing from a list the
/// robot squeezed into one Bluetooth message.
struct OnboardingNetworkStep: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            title: String(localized: .reachy("Choose a network")),
            message: String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "The robot joins this network and then talks to the app over it. Bluetooth is only here to get it that far."
                )
            )
        ) {
            if model.isAlreadyOnNetwork {
                Section {
                    Label(.reachy("This robot is already on a network."), systemImage: "checkmark.circle")
                        .foregroundStyle(Tone.success.style)
                    Button(.reachy("Keep it there and finish")) {
                        model.skipNetwork()
                    }
                }
            }
            Section {
                NetworkCredentialsFields(
                    networks: model.networks,
                    selected: Binding(get: { model.selectedSSID }, set: { model.selectedSSID = $0 }),
                    manualSSID: Binding(get: { model.manualSSID }, set: { model.manualSSID = $0 }),
                    password: Binding(get: { model.password }, set: { model.password = $0 }),
                    isScanning: model.isBusy
                ) {
                    Task { await model.loadNetworks() }
                }
            } footer: {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(
                        .reachy(
                            // swiftlint:disable:next line_length
                            "The robot fits only a handful of names into one Bluetooth message and cannot say how many it left out, so a network missing from the list is normal — type it in under \"Other network…\"."
                        )
                    )
                    Label(
                        .reachy(
                            // swiftlint:disable:next line_length
                            "The password is encrypted for this robot before it is sent, but someone within Bluetooth range could still interfere with the exchange. Set the robot up somewhere you trust."
                        ),
                        systemImage: "lock.trianglebadge.exclamationmark"
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
            ReachyActionButton(.reachy("Send to the robot"), fullWidth: true) {
                Task { await model.join() }
            }
            .disabled(!model.canJoin)
            OnboardingBackButton(model: model)
        }
    }
}
