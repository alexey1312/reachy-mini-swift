import ReachyDesign
import ReachyKit
import SwiftUI

/// The daemon on this very machine, which is how a Lite robot and a simulator are
/// reached.
///
/// Both are the same daemon a Wireless robot runs, started on the reader's own
/// computer — `--serialport` for the robot wired to it, `--sim` for no robot at
/// all — so this adds no transport and no capability. What it adds is the address:
/// `127.0.0.1` was always typeable in the Manual segment, and a Lite owner had no
/// way to know that was the answer.
///
/// **macOS and the Simulator only**, mounted by the caller. There is no daemon on a
/// phone to find, and offering the row there would be a button that cannot work;
/// `ManualAddressSection`'s footer carries the iOS half of this instead.
///
/// **Mounted for the whole life of the gate**, footer included, for the reason this
/// screen's `AGENTS.md` insists on: the candidate sweep beats every 10 s and walks
/// the phase `idle → handshaking → idle` forever while nothing answers, so anything
/// that appears and disappears with an attempt makes the screen compress and expand
/// on a heartbeat the reader cannot see. Only the row's own label and the footer's
/// sentence change here, and both change on a probe result rather than on a timer.
struct LocalDaemonSection: View {
    let model: LocalDaemonModel
    var connect: (RobotAddress) -> Void

    var body: some View {
        Section {
            Button {
                connect(model.address)
            } label: {
                LabeledContent(.reachy("On this computer")) {
                    KnownRobotStatusLabel(status: model.status)
                }
            }
            // A row that cannot connect, with the reason directly beneath it —
            // `MaintenanceCard`'s rule. Disabling on a probe result is safe where
            // disabling on `session.phase` would not be: this flips when a daemon
            // starts or stops, not five times a minute.
            .disabled(model.status == .unreachable)
        } header: {
            Text(.reachy("Lite robot or simulator"))
        } footer: {
            Text(footer)
        }
    }

    /// One sentence, always present, changing with the answer rather than appearing
    /// with it. The unreachable case is the one that has to teach something, because
    /// it is the state a reader with no daemon running will spend all their time in
    /// — and "start the daemon" is the whole of what they can do about it.
    private var footer: LocalizedStringResource {
        switch model.status {
        case .checking:
            .reachy("Looking for a daemon on this computer…")
        case .reachable:
            .reachy("A daemon is running here. This is how a Lite robot and the simulator are reached.")
        case .unreachable:
            .reachy(
                // swiftlint:disable:next line_length
                "Nothing is serving on this computer. A Lite robot is driven by the daemon on the computer it is plugged into, and the simulator is that same daemon with no robot — start one and it appears here."
            )
        }
    }
}
