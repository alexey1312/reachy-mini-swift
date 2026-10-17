import Foundation
import ReachyTeleop

/// The listener's head as headphones report it, relative to where it looked when
/// it was last centred. Core Motion's own three angles, in radians, before any of
/// them is turned into the robot's convention.
struct HeadAttitude: Equatable, Sendable {
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0

    static let level = HeadAttitude()
}

/// Turns a head's attitude into the robot's (the AirPods spike).
///
/// **The reach is measured, not the pad's.** The pad never combines pitch with roll,
/// because roll is a slider of its own, but a head does. With ±40° on every axis the
/// first device run knocked the head against its stops. The daemon checks no collision
/// by default (`check_collision` is false), and its analytical IK solves poses that
/// put a Stewart motor past the URDF limit, for example 40° up with 35° of roll.
/// The numbers below come from the daemon's own `AnalyticalKinematics` and the URDF
/// limits of `stewart_1…6`: on a 2.5° grid over yaw ±40°, all 19 041 poses inside
/// this region solve and keep every motor inside its limit. The region is a
/// comfortable range rather than a safety limit, and the limits stay in the daemon
/// (project rule 2).
///
/// **The signs are a guess until somebody wears the headphones.** Core Motion reports
/// a headphone's attitude in a frame of its own, and nothing short of a device says
/// which way each angle runs. The defaults assume a right-handed frame with its
/// vertical axis up, which makes a turn to the left a positive yaw and a nod down a
/// negative pitch — the reason `pitchSign` is the one that starts at -1. A wrong sign
/// shows at once on the robot, and it is one number here.
struct HeadphoneMotionMapping: Equatable, Sendable {
    var yawReach = 40.0 * .pi / 180
    /// Pitch is positive looking down. Down is the motors' short side
    /// (48° alone), and up loses most of its reach once roll joins it.
    var pitchDownReach = 35.0 * .pi / 180
    var pitchUpReach = 30.0 * .pi / 180
    var rollReach = 30.0 * .pi / 180
    /// Pitch and roll together, as one tilt away from upright. The per-axis limits
    /// alone still allow 30° up with 30° of roll, and that corner is past a motor.
    var tiltReach = 35.0 * .pi / 180
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
        let yaw = axis(attitude.yaw, sign: yawSign).clamped(to: -yawReach ... yawReach)
        var pitch = axis(attitude.pitch, sign: pitchSign).clamped(to: -pitchUpReach ... pitchDownReach)
        var roll = axis(attitude.roll, sign: rollSign).clamped(to: -rollReach ... rollReach)
        // Scaled toward upright rather than clamped per axis, so a head past the cone
        // keeps the direction it leans in and only loses distance.
        let tilt = (pitch * pitch + roll * roll).squareRoot()
        if tilt > tiltReach {
            pitch *= tiltReach / tilt
            roll *= tiltReach / tilt
        }
        return HeadAim(yaw: yaw, pitch: pitch, roll: roll)
    }

    /// The deadzone is taken off the angle rather than applied as a threshold, so the
    /// robot starts moving from zero at its edge instead of jumping by its width.
    private func axis(_ angle: Double, sign: Double) -> Double {
        let magnitude = max(abs(angle) - deadzone, 0)
        guard magnitude > 0 else { return 0 }
        return (angle < 0 ? -magnitude : magnitude) * gain * sign
    }
}
