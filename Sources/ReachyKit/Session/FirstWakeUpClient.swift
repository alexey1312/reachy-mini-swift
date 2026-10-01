import Foundation

/// The robot's own record of whether its owner has been through a first wake-up.
///
/// Daemon 1.10.0 keeps one robot-wide boolean, `first_wake_up_completed`, in the
/// config file beside the startup app, so a setup wizard is shown once per robot
/// rather than once per app (pollen-robotics/reachy_mini#1340). Pollen's mobile app
/// reads it when a session goes live and, while it is `false`, holds the robot
/// asleep and runs its wizard instead.
///
/// **A capability, not a default on `RobotAPIClient`**, because only one transport
/// can answer it: the flag is on the data channel and nowhere else. No REST route
/// exists on any daemon up to `main` — the open desktop wizard
/// (reachy-mini-desktop-app#225) is written against an `/api/first-wake-up/*` that
/// was never merged — and `/ws/sdk` *executes* `set_first_wake_up` while answering
/// nothing at all, so a LAN write could not be confirmed and a LAN read could not be
/// made. `RobotConnection` conforms the day a route lands, and nothing above this
/// protocol changes.
public protocol FirstWakeUpClient: Sendable {
    /// Whether the robot has been through its first wake-up. A daemon that cannot
    /// store the flag reads it as `false` rather than failing.
    func firstWakeUpCompleted() async throws -> Bool

    /// Stores the flag and answers what the robot holds afterwards — which is the
    /// old value when it could not write, so a caller compares rather than assumes.
    @discardableResult
    func setFirstWakeUpCompleted(_ completed: Bool) async throws -> Bool
}
