import ReachyDesign
import SwiftUI

/// The way in to a robot that is not there.
///
/// **A segment of its own rather than a row under "This network", and the
/// neighbour is why.** `LocalDaemonSection` offers the daemon running on this very
/// Mac — a Lite robot plugged in, or upstream's Python simulator under `--sim`.
/// Both of those are a real daemon at an address, discovered by probing loopback.
/// This is the opposite: no daemon, no address, no network, and the only one of
/// the three that works on a phone. Listing them together would say they are
/// alternatives to each other.
struct SimulatorSection: View {
    let isConnecting: Bool
    let connect: () -> Void

    var body: some View {
        Section {
            Button(.reachy("Start the simulator"), action: connect)
                .disabled(isConnecting)
        } header: {
            Text(.reachy("No robot"))
        } footer: {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text(.reachy(
                    // swiftlint:disable:next line_length
                    "A robot drawn from its own description, with no hardware and no physics. The joystick moves it, and the 3D model follows exactly as it would over the network."
                ))
                Text(.reachy(
                    "There is no camera, no app store and no Wi-Fi — those belong to a machine that is not there."
                ))
            }
        }
    }
}
