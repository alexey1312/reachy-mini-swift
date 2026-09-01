import Foundation

/// Subscribing to the robot's pushed pose.
///
/// A file of its own for the reason `+Apps` and `+Wireless` are: the connection
/// itself is at SwiftLint's length limit.
public extension RemoteRobotConnection {
    /// Asks the robot to start writing its state to the `pose` channel.
    ///
    /// Sent rather than performed, the way `subscribe_logs` is: the daemon starts
    /// the publisher and answers nothing, so waiting would sit out the whole budget
    /// and then report a robot that had in fact obeyed.
    func subscribeToPose() async throws {
        try await control.send("subscribe_pose")
    }

    func unsubscribeFromPose() async throws {
        try await control.send("unsubscribe_pose")
    }
}
