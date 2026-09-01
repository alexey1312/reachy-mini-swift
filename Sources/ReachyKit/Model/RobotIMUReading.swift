import Foundation
import simd

/// The robot's inertial reading: what it feels, not what it was told.
///
/// **Wireless only.** `/api/state/imu` answers null on a Lite unit and in
/// simulation, both of which have no BMI088, and also when the cached reading has
/// gone stale — so absent is an ordinary answer rather than a failure.
///
/// The vectors are fixed-width rather than arrays, so a reading that exists has
/// three axes and four quaternion components by construction. Length used to be a
/// promise the doc made and every reader had to re-check, which is why
/// ``tiltDegrees`` was optional and a malformed frame was indistinguishable from a
/// robot with no sensor.
public struct RobotIMUReading: Sendable, Equatable {
    /// Metres per second squared.
    public let accelerometer: SIMD3<Double>
    /// Radians per second.
    public let gyroscope: SIMD3<Double>
    /// w-first, as the daemon sends it: `[w, x, y, z]`.
    public let quaternion: SIMD4<Double>
    public let temperatureCelsius: Double

    public init(
        accelerometer: SIMD3<Double>,
        gyroscope: SIMD3<Double>,
        quaternion: SIMD4<Double>,
        temperatureCelsius: Double
    ) {
        self.accelerometer = accelerometer
        self.gyroscope = gyroscope
        self.quaternion = quaternion
        self.temperatureCelsius = temperatureCelsius
    }

    /// From the three flat arrays the wire carries, or nil when any of them is the
    /// wrong length.
    ///
    /// The one thing a caller cannot fix, and the only place the check belongs: a
    /// transport that answers this with nil is reporting no usable reading, which
    /// is what `imuReading()` already means.
    public init?(
        accelerometer: [Double],
        gyroscope: [Double],
        quaternion: [Double],
        temperatureCelsius: Double
    ) {
        guard accelerometer.count == 3, gyroscope.count == 3, quaternion.count == 4 else {
            return nil
        }
        self.init(
            accelerometer: SIMD3(accelerometer[0], accelerometer[1], accelerometer[2]),
            gyroscope: SIMD3(gyroscope[0], gyroscope[1], gyroscope[2]),
            quaternion: SIMD4(quaternion[0], quaternion[1], quaternion[2], quaternion[3]),
            temperatureCelsius: temperatureCelsius
        )
    }

    /// How far the robot leans from upright, in degrees.
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
    public var tiltDegrees: Double {
        // Clamped because floating-point error can put a unit quaternion's own
        // axis a hair outside `[-1, 1]`, where `acos` answers `nan` rather than 0.
        // Indexed rather than named: the wire is w-first, so `SIMD4.y` is the
        // quaternion's *x*, and reading those names as the quaternion's is the one
        // mistake this shape invites.
        let x = quaternion[1]
        let y = quaternion[2]
        let upright = (1 - 2 * (x * x + y * y)).clamped(to: -1 ... 1)
        return acos(upright) * 180 / .pi
    }
}
