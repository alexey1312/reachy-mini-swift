import ReachyDesign
import ReachyKit
import SwiftUI

/// Ends the Bluetooth session and hands the robot to the ordinary network sweep.
///
/// The hardware id is the whole point of this screen: the robot is about to appear at an
/// address nobody has seen yet, and its identity is the only thing that carries across
/// (rule 4).
struct OnboardingHandoffStep: View {
    let model: OnboardingModel
    var onFinish: (OnboardingOutcome) -> Void

    var body: some View {
        OnboardingStepScaffold(
            title: String(localized: .reachy("All set")),
            message: String(
                localized: .reachy("Bluetooth's job is done. The app will pick the robot up on the network from here.")
            )
        ) {
            if let hardwareID = model.session?.hardwareID {
                LabeledContent(.reachy("Hardware ID")) {
                    Text(hardwareID)
                        .font(Typography.consoleLine)
                }
            }
            if let address = model.session?.robotAddress {
                LabeledContent(.reachy("Address")) {
                    Text(address)
                        .font(Typography.consoleLine)
                }
            }
            Label(
                .reachy(
                    "If this phone is on the robot's own reachy-mini-ap network, switch it back to your home Wi-Fi now."
                ),
                systemImage: "wifi.router"
            )
            .font(Typography.footer)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Label(
                .reachy("You can give the robot a name in Settings once it is connected."),
                systemImage: "tag"
            )
            .font(Typography.footer)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button(.reachy("Done")) {
                onFinish(model.finish())
            }
            .reachyButton(.prominent)
            .frame(maxWidth: .infinity)
        }
    }
}
