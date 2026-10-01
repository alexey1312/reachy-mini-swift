import Foundation
import OSLog

/// Telling the robot it is no longer new (#157).
///
/// Pollen's apps gate a first-run wizard on the robot's `first_wake_up_completed`
/// flag — welcome, name, motors, camera, microphone, speaker — and the mobile app
/// keeps the robot asleep until it has run. So a robot its owner has been using
/// through this app would be greeted as new the first time they open theirs. The
/// other direction needs nothing yet: this app has no first run for the flag to
/// skip.
///
/// **The moment that counts is the first wake-up this app performs**, which is the
/// flag's own name for it: the owner asked for the robot, and it stood up. Not a
/// connect — a connect proves the robot is online, not that anybody has met it —
/// and not the end of Bluetooth setup, where the robot is not on any channel that
/// could store it yet. A first run of this app's own would replace this moment,
/// not add a second one.
extension RobotSession {
    private nonisolated static let firstWakeUpLog = Logger(
        subsystem: "com.alexey1312.ReachyMini",
        category: "FirstWakeUp"
    )

    /// Reads before it writes, so a robot already marked costs one read and no disk
    /// write on the robot's side. Never reported: a flag the owner cannot see is
    /// not a power failure, and `robotError` is power and connection only
    /// (`RobotSessionErrorOwnershipTests`). The failure is logged through
    /// `message(for:)`, the one place daemon failures are.
    ///
    /// Gated on the version as well as the transport: a 1.9.x daemon on the relay
    /// has no such command and would spend the whole reply budget saying so.
    func recordFirstWakeUp(using client: any RobotAPIClient) async {
        guard isAwake, !predatesRelayCommands, let flag = client as? any FirstWakeUpClient else { return }
        do {
            guard try await !flag.firstWakeUpCompleted() else { return }
            guard try await flag.setFirstWakeUpCompleted(true) else {
                Self.firstWakeUpLog.error("the robot could not store its first wake-up")
                return
            }
        } catch {
            _ = Self.message(for: error)
        }
    }
}
