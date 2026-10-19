import Foundation
import OSLog

/// Which robot an automatic attempt may take: the one this device connected to last.
///
/// The candidate sweep dials whatever answers. Another unit can hold the fallback
/// `reachy-mini.local` name or the old DHCP lease of this one, and two units share the
/// default name `reachy_mini`, so nothing on screen tells them apart. A third party
/// measured both on one LAN (`docs/research/wireless-cpu-and-mdns.md`). So `settle`
/// compares hardware ids before it claims or remembers anything (rule 4), and an
/// answer from another robot is, for the sweep, an address that failed.
extension RobotSession {
    /// Whether an automatic attempt may take the robot that answered.
    ///
    /// - With no hardware id held — no robot yet, or a last robot that reported
    ///   none — the first daemon that answers is taken, as before.
    /// - A daemon that reports no hardware id cannot prove it is the held robot,
    ///   so `nil` matches nothing.
    /// - A robot set up over Bluetooth a moment ago is taken: the user asked for it.
    ///
    /// A manual connect never asks, and it is how the user moves the hold to another robot.
    func admitsAutomatically(_ identity: RobotIdentity) -> Bool {
        guard let expected = knownRobots.lastHardwareID else { return true }
        guard let reported = identity.hardwareID else { return false }
        return reported == expected || reported == knownRobots.pendingProvisionedHardwareID
    }

    /// Called before the attempt resets, while `address` still names what was dialled.
    func logPassingOver(_ identity: RobotIdentity) {
        let dialled = address?.displayString ?? "?"
        let reported = identity.hardwareID ?? "no hardware id"
        let expected = knownRobots.lastHardwareID ?? "?"
        let message = "Passed over \(reported) at \(dialled), held to \(expected)"
        Self.automaticConnectLog.info("\(message, privacy: .public)")
    }

    private nonisolated static let automaticConnectLog = Logger(
        subsystem: "com.alexey1312.ReachyMini",
        category: "AutomaticConnect"
    )
}
