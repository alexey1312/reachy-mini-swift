import Foundation

/// The listener's head as headphones report it, relative to where it looked when
/// it was last centred. Core Motion's own three angles, in radians, before any of
/// them is turned into the robot's convention.
struct HeadAttitude: Equatable, Sendable {
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0

    static let level = HeadAttitude()
}

/// A head pose in the robot's convention, measured from the body like every angle
/// the pad produces: yaw is positive to the robot's left, pitch positive looking
/// down, roll positive with the right ear down.
struct HeadAim: Equatable, Sendable {
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0

    static let zero = HeadAim()
}

/// Turns a head's attitude into the robot's (the AirPods spike).
///
/// **Every reach here is the pad's.** `headAngle` is `JoystickMapping.headAngle`, so
/// following a head can never ask more than a thumb can — and it stays under the
/// ~50° past which the daemon drops a pose without a word
/// (pollen-robotics/reachy_mini#1449, where the documented ±40° clamp turned out not
/// to exist). That is a comfortable range rather than a safety limit: the limits stay
/// in the daemon (project rule 2).
///
/// **The signs are a guess until somebody wears the headphones.** Core Motion reports
/// a headphone's attitude in a frame of its own, and nothing short of a device says
/// which way each angle runs. The defaults assume a right-handed frame with its
/// vertical axis up, which makes a turn to the left a positive yaw and a nod down a
/// negative pitch — the reason `pitchSign` is the one that starts at -1. A wrong sign
/// shows at once on the robot, and it is one number here.
struct HeadphoneMotionMapping: Equatable, Sendable {
    var headAngle = JoystickMapping().headAngle
    /// A head held still is not perfectly still. Below this the robot does not move,
    /// so a reader looking at the screen does not get a robot that trembles with them.
    var deadzone = 1.5 * .pi / 180
    /// One degree of head for one degree of robot. A feel constant like every other
    /// in the teleop path.
    var gain = 1.0
    var yawSign = 1.0
    var pitchSign = -1.0
    var rollSign = 1.0

    func aim(_ attitude: HeadAttitude) -> HeadAim {
        HeadAim(
            yaw: axis(attitude.yaw, sign: yawSign),
            pitch: axis(attitude.pitch, sign: pitchSign),
            roll: axis(attitude.roll, sign: rollSign)
        )
    }

    /// The deadzone is taken off the angle rather than applied as a threshold, so the
    /// robot starts moving from zero at its edge instead of jumping by its width.
    private func axis(_ angle: Double, sign: Double) -> Double {
        let magnitude = max(abs(angle) - deadzone, 0)
        guard magnitude > 0 else { return 0 }
        let value = (angle < 0 ? -magnitude : magnitude) * gain * sign
        return value.clamped(to: -headAngle ... headAngle)
    }
}
