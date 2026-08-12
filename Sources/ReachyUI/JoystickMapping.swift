import Foundation

/// Where the knob sits, normalized to the pad's radius.
struct JoystickDeflection: Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0

    static let zero = JoystickDeflection()
}

/// Which rotation zone a deflection is in.
///
/// It lives beside the mapping rather than beside the pad because the mapping is
/// what decides it — the pad only draws what it is told.
enum JoystickRotationSide: Equatable, Sendable {
    case left, right
}

/// Turns a joystick deflection into a head pose and a body rotation speed.
///
/// A vertical line at `±rotationThreshold` cuts the pad into three bands: inside it
/// sideways travel is head yaw, and the whole slice beyond it — its top and bottom
/// corners as much as its middle — turns the body, at a speed that grows from zero at
/// the boundary. `maxBodyYawRate` must stay below `TargetSlewLimiter.bodyYawRate` or
/// the limiter would cap the turn rather than merely smooth it.
///
/// **The boundary is a straight line and not a radius**, because it is also where head
/// yaw reaches its full lead: the head stops moving out exactly as the body starts,
/// which is what makes the handover continuous. A radial zone would part the two — a
/// push into the corner is far from the centre while its sideways component is not, so
/// the body would begin turning under a head still halfway through its own travel.
///
/// **Every angle here is measured from the body, never from the room.** The daemon's
/// `target_head_pose` is the other way round, so `TeleopDriver` adds the body's own
/// yaw before anything reaches the wire; nothing on a pad centred on the torso can
/// mean an absolute direction.
struct JoystickMapping: Equatable, Sendable {
    /// Where head yaw ends and body rotation begins, as a fraction of the pad's
    /// sideways travel.
    ///
    /// It was 0.7, which on a round pad put the boundary outside the diagonal: the rim
    /// only reaches `|x| = 0.7` within 45.6° of level, so a thumb pushed hard left and
    /// a little up sat against the edge of the pad and the robot did not turn — the
    /// zone read as "strictly left and right" because that is what it was. Half the
    /// travel puts the boundary at 60° off level, so every direction from level out to
    /// past the diagonal turns the body, and the zone covers two thirds of each side
    /// of the pad rather than half.
    ///
    /// A feel constant: it costs head-yaw resolution (the full ±`headAngle` now
    /// arrives at half travel), and only the robot can settle whether that trade is
    /// right.
    var rotationThreshold = 0.5
    /// Comfortable head range; the daemon clamps anyway.
    var headAngle = 40.0 * .pi / 180
    /// Radians per second at full sideways deflection — a half turn in three seconds.
    var maxBodyYawRate = 60.0 * .pi / 180
    /// How much of the head's lead the body takes over across the rotation zone.
    ///
    /// 1 hands it all back, so at full deflection the head sits exactly on the torso's
    /// axis and the camera looks straight down it. 0 is what this did before the head
    /// was composed with the body at all: the head keeps its ±`headAngle` lead for the
    /// whole turn.
    ///
    /// The price of 1 is that world head yaw is a tent in thumb travel — crossing the
    /// zone gives 40° back while the body has barely started, so the camera swings
    /// against the push and the body needs `headAngle / maxBodyYawRate` to repay it.
    /// A feel constant like the rest of this type: only the robot settles it.
    var headRecentring = 1.0

    /// How far past the rotation boundary the knob is: 0 at the boundary, 1 at full
    /// sideways travel.
    ///
    /// The one place the zone's shape is written down, so the head's recentring and
    /// the body's speed cannot disagree about where the turn begins.
    func rotationRamp(_ deflection: JoystickDeflection) -> Double {
        let over = abs(deflection.x) - rotationThreshold
        guard over > 0 else { return 0 }
        return (over / (1 - rotationThreshold)).clamped(to: 0 ... 1)
    }

    /// Head yaw relative to the body: full ±`headAngle` at the boundary, and back to
    /// zero at full deflection as the body takes the pan over.
    func headYaw(_ deflection: JoystickDeflection) -> Double {
        let leading = -(deflection.x / rotationThreshold).clamped(to: -1 ... 1) * headAngle
        return leading * (1 - headRecentring * rotationRamp(deflection))
    }

    func headPitch(_ deflection: JoystickDeflection) -> Double {
        deflection.y * headAngle
    }

    /// Radians per second, zero inside the head zone. Signed like `headYaw`, so the
    /// head and the body turn the same way for the same push.
    func bodyYawRate(_ deflection: JoystickDeflection) -> Double {
        let ramp = rotationRamp(deflection)
        guard ramp > 0 else { return 0 }
        return deflection.x < 0 ? ramp * maxBodyYawRate : -ramp * maxBodyYawRate
    }

    /// Which zone the knob is in, if any — defined as "the body is turning", so the
    /// slice the pad shades and the rotation that slice stands for cannot disagree.
    func rotationSide(_ deflection: JoystickDeflection) -> JoystickRotationSide? {
        guard bodyYawRate(deflection) != 0 else { return nil }
        return deflection.x > 0 ? .right : .left
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
