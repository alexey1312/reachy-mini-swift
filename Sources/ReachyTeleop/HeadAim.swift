import Foundation

/// A head pose in the robot's convention, measured from the body like every angle
/// the pad produces: yaw is positive to the robot's left, pitch positive looking
/// down, roll positive with the right ear down.
public struct HeadAim: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    public static let zero = HeadAim()
}
