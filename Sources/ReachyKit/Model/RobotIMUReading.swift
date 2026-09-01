import Foundation

/// The robot's inertial reading: what it feels, not what it was told.
///
/// **Wireless only.** `/api/state/imu` answers null on a Lite unit and in
/// simulation, both of which have no BMI088, and also when the cached reading has
/// gone stale — so absent is an ordinary answer rather than a failure.
public struct RobotIMUReading: Sendable, Equatable {
    /// Metres per second squared.
    public let accelerometer: [Double]
    /// Radians per second.
    public let gyroscope: [Double]
    /// The daemon sends this w-first: `[w, x, y, z]`.
    public let quaternion: [Double]
    public let temperatureCelsius: Double

    public init(
        accelerometer: [Double],
        gyroscope: [Double],
        quaternion: [Double],
        temperatureCelsius: Double
    ) {
        self.accelerometer = accelerometer
        self.gyroscope = gyroscope
        self.quaternion = quaternion
        self.temperatureCelsius = temperatureCelsius
    }

    /// How far the robot leans from upright, in degrees, or nil for a quaternion
    /// this build cannot read.
    ///
    /// From the orientation rather than from the accelerometer, and that is the
    /// whole point: an accelerometer reads *any* acceleration, so a robot in the
    /// middle of a dance would report itself falling over. The quaternion says
    /// where the robot's own up-axis points, and the angle between that and the
    /// world's is the lean.
    ///
    /// Only the axis matters, so the arithmetic reduces to the rotated axis'
    /// vertical component — `1 − 2(x² + y²)` — and yaw drops out untouched, which
    /// is correct: a robot turned to face the other way is no less upright.
    public var tiltDegrees: Double? {
        guard quaternion.count == 4 else { return nil }
        let x = quaternion[1]
        let y = quaternion[2]
        // Clamped because floating-point error can put a unit quaternion's own
        // axis a hair outside `[-1, 1]`, where `acos` answers `nan` rather than 0.
        let upright = (1 - 2 * (x * x + y * y)).clamped(to: -1 ... 1)
        return acos(upright) * 180 / .pi
    }
}
