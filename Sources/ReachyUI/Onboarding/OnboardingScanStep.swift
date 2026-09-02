import ReachyDesign
import ReachyKit
import SwiftUI

/// Picks one robot out of everything advertising the provisioning service.
///
/// Every robot advertises the same local name, so the list is ordered by signal strength
/// and says so — until one is connected there is nothing else to tell them apart by.
struct OnboardingScanStep: View {
    let model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            title: String(localized: .reachy("Find the robot")),
            message: message
        ) {
            switch model.availability {
            case .ready, .unknown:
                results
            case .poweredOff:
                unavailable(
                    String(localized: .reachy("Bluetooth is switched off")),
                    detail: String(
                        localized: .reachy("Turn it on in Control Centre or Settings, and this list will fill in.")
                    )
                )
            case .unauthorized:
                unavailable(
                    String(localized: .reachy("This app can't use Bluetooth")),
                    detail: String(localized: .reachy("Allow Bluetooth for this app in Settings, then come back."))
                )
                PrivacySettingsButton(pane: .bluetooth)
            case .unsupported:
                unavailable(
                    String(localized: .reachy("This device has no Bluetooth")),
                    detail: String(
                        localized: .reachy(
                            "The iOS Simulator never has any. Set the robot up from a real device, or join "
                        )
                    )
                        +
                        String(
                            localized: .reachy(
                                "its own reachy-mini-ap network and configure it over Wi-Fi instead."
                            )
                        )
                )
            }
            // Only where the panel above has not already said it. An unusable radio makes
            // the scan fail with the same sentence, and printing it again underneath in
            // red reads as a second, worse problem.
            if radioIsUsable {
                OnboardingErrorText(message: model.errorMessage)
            }
        } actions: {
            if let only = model.discovered.first, model.discovered.count == 1 {
                Button(.reachy("Connect to this robot")) {
                    Task { await model.connect(to: only.id) }
                }
                .reachyButton(.prominent)
                .frame(maxWidth: .infinity)
                .disabled(model.isBusy)
            }
            OnboardingBackButton(model: model)
        }
    }

    private var radioIsUsable: Bool {
        model.availability == .ready || model.availability == .unknown
    }

    private var message: String {
        switch model.availability {
        case .ready, .unknown:
            String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "Robots all advertise the same name, so they are listed by signal strength. The nearest one is at the top."
                )
            )
        default:
            String(localized: .reachy("Setting a robot up needs Bluetooth."))
        }
    }

    @ViewBuilder
    private var results: some View {
        if model.discovered.isEmpty {
            // Optical: the signal glyph sits beside the robot's name as one row.
            // swiftlint:disable:next raw_spacing
            HStack(spacing: 10) {
                ProgressView()
                Text(.reachy("Searching…"))
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(model.discovered) { robot in
            Button {
                Task { await model.connect(to: robot.id) }
            } label: {
                LabeledContent {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Text(.reachy("\(robot.rssi) dBm"))
                            .font(Typography.consoleLine)
                    }
                } label: {
                    Label(robot.name, systemImage: "dot.radiowaves.left.and.right")
                }
            }
            .reachyButton()
            .disabled(model.isBusy)
        }
    }

    private func unavailable(_ title: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "antenna.radiowaves.left.and.right.slash", description: Text(detail))
    }
}
