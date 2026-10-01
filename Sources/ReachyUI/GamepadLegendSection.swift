import ReachyDesign
import SwiftUI

/// What each control on a connected game controller does (#160).
///
/// Shown only while one is connected: a legend for a controller nobody has is a
/// paragraph about hardware on a screen about the robot. The controls are named by
/// position rather than by letter, because the letters are not the same on any two
/// makes — the right face button is B on an Xbox controller, ○ on a PlayStation one
/// and A on a Switch one. The action leads each row and the control trails it, so the
/// column a reader scans is the one that says what the robot will do.
struct GamepadLegendSection: View {
    /// The controller's own name, as the system reports it — runtime text, like a
    /// robot's name, so it is shown as it arrives.
    let controllerName: String

    var body: some View {
        Section {
            Label(controllerName, systemImage: "gamecontroller")
            row(.reachy("Look around"), control: .reachy("Right stick"))
            row(.reachy("Turn the body"), control: .reachy("Left stick, sideways"))
            row(.reachy("Raise or lower the head"), control: .reachy("Left stick, up and down"))
            row(.reachy("Tilt the head"), control: .reachy("Shoulder buttons"))
            row(.reachy("Move the antennas"), control: .reachy("Triggers"))
            row(.reachy("Reset to neutral"), control: .reachy("Right face button"))
        } header: {
            Text(.reachy("Game controller"))
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "The d-pad works like the left stick. Hold the right stick at its side to turn the body as you look."
                )
            )
        }
    }

    private func row(_ action: LocalizedStringResource, control: LocalizedStringResource) -> some View {
        LabeledContent {
            Text(control)
        } label: {
            Text(action)
        }
    }
}
