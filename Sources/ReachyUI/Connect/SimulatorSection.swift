import ReachyDesign
import SwiftUI

/// The way in to a robot that is not there.
///
/// **Rows under the Developer disclosure, not a segment.** It was a third segment
/// beside the two real ways in, and the neighbour argument still holds:
/// `LocalDaemonSection` offers a real daemon at an address on this Mac, while this
/// is no daemon, no address and no network — but neither of those is a reason to
/// put it on the app's first screen for a reader who owns a robot. The disclosure
/// is where the two are told apart.
///
/// Rows rather than a `Section`, so the host decides the grouping: inside a
/// `DisclosureGroup` a nested section renders as a second header.
struct SimulatorSection: View {
    let isConnecting: Bool
    let connect: () -> Void

    var body: some View {
        Button(.reachy("Start the simulator"), action: connect)
            .disabled(isConnecting)
        Text(.reachy(
            // swiftlint:disable:next line_length
            "A robot drawn from its own description, with no hardware and no physics. The joystick moves it, and the 3D model follows exactly as it would over the network."
        ))
        .font(Typography.footer)
        .foregroundStyle(.secondary)
        Text(.reachy(
            "There is no camera, no app store and no Wi-Fi — those belong to a machine that is not there."
        ))
        .font(Typography.footer)
        .foregroundStyle(.secondary)
    }
}
