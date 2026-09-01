import Foundation
import ReachyJSON

/// The daemon's `StateSnapshot`, which is what both the `get_state` reply and the
/// pushed pose frames carry.
///
/// A type of its own because the two transports name the same values differently
/// from the WebSocket stream — `antennas` against `antennas_position`, a nested
/// 4x4 against a flat sixteen — so ``RobotStateFrame`` cannot decode either
/// directly. This is the translation, in one place rather than two.
struct RemoteStateSnapshot: Decodable {
    /// Row-major 4x4, nested as the daemon nests it.
    let headPose: [[Double]]?
    let bodyYaw: Double?
    /// `(left, right)`, radians.
    let antennas: [Double]?
    /// Absent on a robot with no ReSpeaker, and on a daemon before 1.10.0 — which
    /// is why it is optional rather than merely quiet.
    let doa: DoaSnapshot?

    struct DoaSnapshot: Decodable {
        /// Radians, 0 at the robot's left and π at its right.
        let angle: Double
        let speechDetected: Bool

        enum CodingKeys: String, CodingKey {
            case angle
            case speechDetected = "speech_detected"
        }
    }

    enum CodingKeys: String, CodingKey {
        case headPose = "head_pose"
        case bodyYaw = "body_yaw"
        case antennas
        case doa
    }

    /// Nil where the robot sent no pose at all, which is a backend that is down
    /// rather than an error to report. A snapshot carrying only a direction still
    /// counts: the hearing indicator has something to say even while the robot is
    /// not moving.
    var frame: RobotStateFrame? {
        guard headPose != nil || bodyYaw != nil || antennas != nil || doa != nil else { return nil }
        return RobotStateFrame(
            bodyYaw: bodyYaw,
            antennas: antennas,
            headPose: headPose.map { .matrix($0.flatMap(\.self)) },
            directionOfArrival: doa.map {
                .init(angle: $0.angle, speechDetected: $0.speechDetected)
            }
        )
    }
}

/// One frame off the `pose` channel: a snapshot and the counter that orders it.
struct RemotePoseFrame: Decodable {
    let state: RemoteStateSnapshot
    /// Monotonic per subscription. The channel is unordered, so this is the only
    /// thing that says which of two frames is newer.
    let seq: Int
}
