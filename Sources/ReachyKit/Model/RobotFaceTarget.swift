import Foundation

/// Where the daemon's own face tracker is aimed.
///
/// **The one reading this app has of either presence behaviour.** ``PresenceClient``
/// explains why neither switch can be read back; this does not close that — a face
/// the robot cannot see says nothing about whether tracking is on — but it answers
/// the other half, which is whether the robot has anybody to follow.
public struct RobotFaceTarget: Sendable, Equatable {
    /// Normalised camera coordinates, −1…1 with the origin at the centre of the
    /// frame. Positive `x` is to the robot's right in the image it sees.
    public let x: Double
    public let y: Double
    /// Head roll of the detected face, in radians.
    public let roll: Double

    public init(x: Double, y: Double, roll: Double) {
        self.x = x
        self.y = y
        self.roll = roll
    }

    /// Reads the route's untyped object, or nil where there is no face to report.
    ///
    /// Nil covers both an undetected face and a payload missing the numbers: the
    /// daemon leaves the last aim in place between detections, so a point without
    /// `detected` behind it is stale rather than current.
    ///
    /// **The reading is nested.** The route answers
    /// `{"status": "ok", "face_target": {…}}`, not the target on its own — measured
    /// against a Wireless robot on daemon 1.10.0, after a version that read the top
    /// level found nothing there and would have reported an empty room for ever.
    /// The outer object is accepted too, so a daemon that ever flattens it is not a
    /// regression.
    static func decoded(from payload: [String: (any Sendable)?]) -> RobotFaceTarget? {
        let target = (payload["face_target"] ?? nil) as? [String: (any Sendable)?] ?? payload
        guard (target["detected"] ?? nil) as? Bool == true,
              let x = number(target["x"]), let y = number(target["y"])
        else { return nil }
        return RobotFaceTarget(x: x, y: y, roll: number(target["roll"]) ?? 0)
    }

    /// A JSON number decodes to `Int` or `Double` depending on its value rather than
    /// its field — the reason is written out on `ControlLoopStats.number`.
    private static func number(_ value: (any Sendable)??) -> Double? {
        switch value ?? nil {
        case let value as Double: value
        case let value as Int: Double(value)
        default: nil
        }
    }
}
