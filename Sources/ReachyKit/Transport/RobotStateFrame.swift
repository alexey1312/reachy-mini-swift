import Foundation
import simd

/// A state-stream frame decoded by hand, for consumers that need the geometry.
///
/// The generated `FullState` cannot carry a matrix head pose usefully: the
/// generator does not understand `prefixItems` without `items`, so
/// `Matrix4x4Pose.m` arrives as an untyped `OpenAPIArrayContainer` whose elements
/// have to be cast back from `Any` one by one. Decoding the frame a second time
/// keeps the 3D viewer independent of that quirk, and costs a few microseconds
/// on a ~600-byte payload.
public struct RobotStateFrame: Sendable, Equatable, Decodable {
    public enum HeadPose: Sendable, Equatable {
        /// Sixteen values, row-major, translation in metres.
        case matrix([Double])
        /// Metres and radians.
        case euler(x: Double, y: Double, z: Double, roll: Double, pitch: Double, yaw: Double)

        /// Both forms collapse to the same transform, so callers never branch.
        public var transform: simd_double4x4? {
            switch self {
            case let .matrix(values):
                RigidTransform.matrix(rowMajor: values)
            case let .euler(x, y, z, roll, pitch, yaw):
                RigidTransform.transform(translation: SIMD3(x, y, z), rpy: SIMD3(roll, pitch, yaw))
            }
        }
    }

    public var timestamp: Date?
    public var bodyYaw: Double?
    /// Seven values: `[body_yaw, stewart_1 ... stewart_6]`. Absent unless the
    /// stream was opened with `StateStreamOptions.headJoints`.
    public var headJoints: [Double]?
    /// Two values, `(left, right)`, radians.
    public var antennas: [Double]?
    public var headPose: HeadPose?
    /// Twenty-one values, and only from a Placo-backed daemon.
    public var passiveJoints: [Double]?
    /// Where the robot last heard a voice.
    ///
    /// Carried here rather than read off the generated `FullState` alone, because
    /// the relay has no `FullState` to offer: its snapshot is decoded by hand, and
    /// this is the field the hearing indicator needs from it. The socket leaves it
    /// nil and `StateStreamUpdate.hearing` reads the generated half instead.
    public var directionOfArrival: DirectionOfArrival?

    public struct DirectionOfArrival: Sendable, Equatable {
        /// Radians, 0 at the robot's left and π at its right.
        public let angle: Double
        public let speechDetected: Bool

        public init(angle: Double, speechDetected: Bool) {
            self.angle = angle
            self.speechDetected = speechDetected
        }
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case bodyYaw = "body_yaw"
        case headJoints = "head_joints"
        case antennas = "antennas_position"
        case headPose = "head_pose"
        case passiveJoints = "passive_joints"
    }

    private enum PoseKeys: String, CodingKey {
        case m, x, y, z, roll, pitch, yaw
    }

    /// Declaring `init(from:)` below suppresses the memberwise initialiser, and
    /// nothing needed one while every frame in the app arrived off a socket. A
    /// simulator does not decode frames, it *produces* them — and from another
    /// module, where an internal memberwise init would not be visible even if one
    /// existed.
    public init(
        timestamp: Date? = nil,
        bodyYaw: Double? = nil,
        headJoints: [Double]? = nil,
        antennas: [Double]? = nil,
        headPose: HeadPose? = nil,
        directionOfArrival: DirectionOfArrival? = nil,
        passiveJoints: [Double]? = nil
    ) {
        self.timestamp = timestamp
        self.bodyYaw = bodyYaw
        self.headJoints = headJoints
        self.antennas = antennas
        self.headPose = headPose
        self.directionOfArrival = directionOfArrival
        self.passiveJoints = passiveJoints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        bodyYaw = try container.decodeIfPresent(Double.self, forKey: .bodyYaw)
        headJoints = try container.decodeIfPresent([Double].self, forKey: .headJoints)
        antennas = try container.decodeIfPresent([Double].self, forKey: .antennas)
        passiveJoints = try container.decodeIfPresent([Double].self, forKey: .passiveJoints)
        headPose = try Self.decodeHeadPose(from: container)
    }

    /// `head_pose` is an `anyOf` whose shape follows the stream's `use_pose_matrix`
    /// flag, so the branch is chosen by looking for `m` rather than by trying both.
    private static func decodeHeadPose(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> HeadPose? {
        guard container.contains(.headPose), try !container.decodeNil(forKey: .headPose) else {
            return nil
        }
        let pose = try container.nestedContainer(keyedBy: PoseKeys.self, forKey: .headPose)
        if let values = try pose.decodeIfPresent([Double].self, forKey: .m) {
            return .matrix(values)
        }
        /// Every component defaults to 0 in the daemon's schema.
        func component(_ key: PoseKeys) throws -> Double {
            try pose.decodeIfPresent(Double.self, forKey: key) ?? 0
        }
        return try .euler(
            x: component(.x),
            y: component(.y),
            z: component(.z),
            roll: component(.roll),
            pitch: component(.pitch),
            yaw: component(.yaw)
        )
    }
}
