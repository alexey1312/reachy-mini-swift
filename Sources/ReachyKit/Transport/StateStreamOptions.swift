import Foundation

/// Query parameters for `/api/state/ws/full`.
///
/// FastAPI does not describe WebSocket routes, so these are absent from
/// `openapi.json` and were read off the daemon's own handler signature. Every
/// value is optional: leaving one `nil` omits the parameter and lets the daemon
/// pick, which keeps the default stream byte-identical to a query-less URL.
///
/// - Important: the daemon also accepts `with_target_*` flags, and they are
///   deliberately not representable here. Each one trips an assertion inside the
///   frame builder that a blanket `except` swallows: the socket stays open and
///   never delivers another frame, so a screen built on it looks like it is
///   loading forever rather than failing.
public struct StateStreamOptions: Sendable, Equatable {
    /// Frames per second. The daemon's own default is 10 — not the 20 this
    /// project assumed for a long time.
    public var frequency: Double?
    public var headPose: Bool?
    /// Seven values: `[body_yaw, stewart_1 ... stewart_6]`.
    public var headJoints: Bool?
    public var bodyYaw: Bool?
    public var antennaPositions: Bool?
    /// Stays null unless the daemon was launched with `--kinematics-engine Placo`;
    /// the default analytical engine never computes these.
    public var passiveJoints: Bool?
    public var directionOfArrival: Bool?
    /// Switches `head_pose` from x/y/z + roll/pitch/yaw to a flat 4x4 matrix.
    public var poseAsMatrix: Bool?

    public init() {}

    /// What the 3D viewer needs: motor angles to pose the linkage, and the head
    /// pose as a matrix so no Euler convention has to be guessed.
    public static var visualization: Self {
        var options = Self()
        options.frequency = 20
        options.headPose = true
        options.headJoints = true
        options.bodyYaw = true
        options.antennaPositions = true
        options.poseAsMatrix = true
        return options
    }

    /// Direction of arrival and **nothing else**.
    ///
    /// Every geometry flag is named `false` rather than left `nil`, because the
    /// daemon's own defaults are `true` for three of them (`with_head_pose`,
    /// `with_body_yaw`, `with_antenna_positions`) — a query that only added
    /// `with_doa` would carry a full pose forty times a minute for a two-field
    /// reading.
    ///
    /// 5 Hz because this drives one indicator: a voice arrives, the indicator
    /// lights, and nobody can read it faster than that. The visualization stream
    /// asks for 20 because it is posing a linkage.
    public static var hearing: Self {
        var options = Self()
        options.frequency = 5
        options.headPose = false
        options.headJoints = false
        options.bodyYaw = false
        options.antennaPositions = false
        options.passiveJoints = false
        options.directionOfArrival = true
        return options
    }

    /// Fixed order — the URL is asserted verbatim in tests.
    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let frequency {
            items.append(URLQueryItem(name: "frequency", value: Self.format(frequency)))
        }
        append(&items, "with_head_pose", headPose)
        append(&items, "with_head_joints", headJoints)
        append(&items, "with_body_yaw", bodyYaw)
        append(&items, "with_antenna_positions", antennaPositions)
        append(&items, "with_passive_joints", passiveJoints)
        append(&items, "with_doa", directionOfArrival)
        append(&items, "use_pose_matrix", poseAsMatrix)
        return items
    }

    private func append(_ items: inout [URLQueryItem], _ name: String, _ value: Bool?) {
        guard let value else { return }
        items.append(URLQueryItem(name: name, value: value ? "true" : "false"))
    }

    /// FastAPI parses a bare `20` into a float fine, and it reads better than `20.0`.
    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
