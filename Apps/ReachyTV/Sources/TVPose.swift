import Foundation
import ReachyKit

/// The robot's own head and body angles, as its state stream reports them, for the drive
/// screen to show while somebody drives.
///
/// The TV has no 3D model of the robot, and the in-app simulated robot has no camera, so
/// without this a person driving the simulator — App Review among them — would see nothing
/// move at all. These are the robot's readings, not what the controller asked for: a target
/// the daemon clamps shows as the angle the robot reached.
///
/// The head's yaw is measured from the base, as the daemon reports it; the body's yaw is a
/// joint of its own (`TeleopTarget`).
struct TVPose: Equatable {
    var headYaw: Double
    var headPitch: Double
    var bodyYaw: Double

    /// Ten readings a second, the head as angles rather than as a matrix, and no antennas.
    static var streamOptions: StateStreamOptions {
        var options = StateStreamOptions()
        options.frequency = 10
        options.headPose = true
        options.bodyYaw = true
        options.antennaPositions = false
        options.poseAsMatrix = false
        return options
    }

    init?(_ frame: RobotStateFrame) {
        guard let head = frame.headPose?.yawAndPitch else { return nil }
        headYaw = head.yaw
        headPitch = head.pitch
        bodyYaw = frame.bodyYaw ?? 0
    }

    /// An angle as a reader sees it: whole degrees, signed.
    static func degrees(_ radians: Double) -> String {
        String(format: "%.0f°", radians * 180 / .pi)
    }
}
