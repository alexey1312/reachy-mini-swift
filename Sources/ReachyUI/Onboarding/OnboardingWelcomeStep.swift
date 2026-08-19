import ReachyDesign
import SwiftUI

/// Stands between opening the flow and the first CoreBluetooth call, so the system's
/// Bluetooth prompt arrives on a screen that has already said what it is for.
struct OnboardingWelcomeStep: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            title: String(localized: .reachy("Before you start")),
            message: String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "A new robot has no network yet, so the first conversation happens over Bluetooth. It takes a couple of minutes."
                )
            )
        ) {
            VStack(alignment: .leading, spacing: 14) {
                requirement(
                    String(localized: .reachy("The robot, powered on")),
                    detail: String(
                        localized: .reachy("Give it about a minute after switching on before it starts advertising.")
                    ),
                    icon: "power"
                )
                requirement(
                    String(localized: .reachy("The last five characters of its serial number")),
                    detail: String(
                        localized: .reachy(
                            "The serial is printed on the robot. Capitals matter, and it is not always digits."
                        )
                    ),
                    icon: "numbers.rectangle"
                )
                requirement(
                    String(localized: .reachy("Your Wi-Fi password")),
                    detail: String(localized: .reachy("It is encrypted for the robot before it leaves this device.")),
                    icon: "wifi"
                )
                Label(
                    .reachy("The next screen turns on Bluetooth scanning, so iOS will ask for permission."),
                    systemImage: "info.circle"
                )
                .font(Typography.footer)
                .foregroundStyle(.secondary)
            }
        } actions: {
            Button(.reachy("Start")) {
                model.beginScan()
            }
            .reachyButton(.prominent)
            .frame(maxWidth: .infinity)
        }
    }

    private func requirement(_ title: String, detail: String, icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                Text(detail)
                    .font(Typography.footer)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.tint)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
