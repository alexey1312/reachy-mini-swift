import ReachyDesign
import ReachyKit
import SwiftUI

/// The address field at the foot of the `Local` segment. A first-class way in, not
/// a fallback: one robot can appear at several addresses and discovery reaches
/// neither of them on some networks (upstream issue #269).
///
/// It was a segment of its own until the segments were shortened, and it is under
/// the list now because that is where the list's own copy points — see
/// `ConnectRoute`.
struct ManualAddressSection: View {
    @Binding var input: String
    var connect: (RobotAddress) -> Void

    private var address: RobotAddress? {
        RobotAddress(parsing: input)
    }

    var body: some View {
        Section {
            TextField(.reachy("host, host:port, or IP"), text: $input)
                .autocorrectionDisabled()
            #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            #endif
            Button(.reachy("Connect")) {
                guard let address else { return }
                connect(address)
            }
            .reachyButton(.standard)
            .disabled(address == nil)
        } footer: {
            VStack(alignment: .leading, spacing: Space.sm) {
                // The one thing a typed address cannot tell you it got wrong. A Lite
                // robot and the simulator are the same daemon running on somebody's
                // computer, and `--fastapi-host` defaults to `127.0.0.1` for both —
                // it is only `0.0.0.0` under `--wireless-version`. So the socket is
                // bound to that computer's loopback and a phone on the same Wi-Fi is
                // refused by the kernel before FastAPI is ever reached: same subnet,
                // nothing to do with the network, and no error that says so.
                Text(
                    .reachy(
                        // swiftlint:disable:next line_length
                        "A Lite robot or a simulator is reached at the address of the computer running its software — and only if that software was started with --fastapi-host 0.0.0.0. By default it accepts connections from that computer alone."
                    )
                )
                // A footer sentence, not an orange warning: it is true of every
                // connection this app makes and it is the reader's network, not a
                // fault to fix. An alarm that is always on is one nobody reads.
                Text(.reachy("The connection is plain HTTP without a password, so use a trusted private network."))
            }
        }
    }
}
