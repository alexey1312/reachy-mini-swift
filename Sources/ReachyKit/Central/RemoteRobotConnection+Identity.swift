import Foundation

/// Naming the robot over the relay.
///
/// Daemon 1.10.0 put `get_robot_name` and `set_robot_name` on the data channel,
/// so renaming is reachable from wherever the owner happens to be — which is the
/// point of it: the name is what they picked the robot by.
public extension RemoteRobotConnection {
    /// Renames the robot and answers the name it settled on.
    ///
    /// Satisfies ``RobotAPIClient/setRobotName(_:)``, whose throwing default this
    /// connection used to inherit. The daemon persists it, so it survives a reboot
    /// and the change is live — no restart, which is what makes it worth offering
    /// from a screen rather than from setup.
    func setRobotName(_ name: String) async throws -> String {
        try await control.perform(
            "set_robot_name",
            payload: ["name": .string(name)],
            correlation: .replyKey("robot_name"),
            expecting: RobotNameReply.self
        ).robotName
    }
}

private struct RobotNameReply: Decodable {
    let robotName: String

    enum CodingKeys: String, CodingKey {
        case robotName = "robot_name"
    }
}
