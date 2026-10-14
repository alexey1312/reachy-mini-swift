import ReachyDesign
import SwiftUI

/// The Controller screen's switch for `HeadphoneTeleop` (the AirPods spike).
///
/// Absent wherever the model reads `.unsupported`, which is every Mac, every simulator
/// and every capture that does not hand in a state of its own — so adopting it moved no
/// reference that predates it.
struct HeadTrackingSection: View {
    let model: HeadphoneTeleop

    var body: some View {
        if model.status != .unsupported {
            Section {
                Toggle(.reachy("Follow my head"), isOn: Binding(
                    get: { model.isOn },
                    set: { model.setOn($0) }
                ))
                status
            } header: {
                Text(.reachy("Head tracking"))
            } footer: {
                Text(
                    .reachy(
                        // swiftlint:disable:next line_length
                        "With AirPods or Beats that track your head, the robot turns its head as you turn yours. Look straight ahead when you switch it on."
                    )
                )
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.status {
        case .waiting:
            Text(.reachy("Waiting for headphones that track your head."))
                .foregroundStyle(.secondary)
        case .following:
            // The one control the reader needs while following: their own "straight
            // ahead" drifts as they settle into a chair.
            Button(.reachy("Recentre")) { model.recentre() }
        case .denied:
            Text(.reachy("Motion & Fitness access is turned off"))
                .foregroundStyle(.secondary)
            PrivacySettingsButton(pane: .motion)
        case .off, .unsupported:
            EmptyView()
        }
    }
}
