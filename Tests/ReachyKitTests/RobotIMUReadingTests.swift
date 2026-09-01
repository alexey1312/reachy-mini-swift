import Foundation
@testable import ReachyKit
import Testing

/// The lean is the only thing this app reads out of the quaternion, and it is read
/// rather than measured — so the arithmetic is what these pin.
@Suite("RobotIMUReading")
struct RobotIMUReadingTests {
    private func reading(quaternion: [Double]) -> RobotIMUReading? {
        RobotIMUReading(
            accelerometer: [0, 0, 9.81],
            gyroscope: [0, 0, 0],
            quaternion: quaternion,
            temperatureCelsius: 31.5
        )
    }

    private func tilt(_ quaternion: [Double]) -> Double? {
        reading(quaternion: quaternion)?.tiltDegrees
    }

    @Test("a robot standing straight leans nowhere")
    func upright() throws {
        let degrees = try #require(tilt([1, 0, 0, 0]))
        #expect(abs(degrees) < 0.001)
    }

    /// Yaw is a robot facing the other way, which is no less upright. It has to drop
    /// out of the answer entirely.
    @Test("turning on the spot is not a lean")
    func yawIsNotTilt() throws {
        let degrees = try #require(tilt([Self.cos45, 0, 0, Self.cos45]))
        #expect(abs(degrees) < 0.001)
    }

    private static let cos45 = 0.5.squareRoot()

    @Test("a quarter turn onto its side reads as ninety degrees", arguments: [
        [cos45, cos45, 0, 0],
        [cos45, 0, cos45, 0],
    ])
    func onItsSide(quaternion: [Double]) throws {
        let degrees = try #require(tilt(quaternion))
        #expect(abs(degrees - 90) < 0.001)
    }

    @Test("upside down is a hundred and eighty")
    func upsideDown() throws {
        let degrees = try #require(tilt([0, 1, 0, 0]))
        #expect(abs(degrees - 180) < 0.001)
    }

    /// A quaternion a hair off unit length puts the cosine outside `acos`'s domain,
    /// where it answers `nan` — which would render as a blank row rather than as a
    /// number, and read as "no IMU".
    @Test("a quaternion off unit length still answers a number")
    func survivesRoundingError() throws {
        let degrees = try #require(tilt([1.0000001, 0, 0, 0]))
        #expect(!degrees.isNaN)
        #expect(abs(degrees) < 0.001)
    }

    /// Refused at construction rather than answered with a nil tilt: a reading that
    /// exists has four components, so every reader is spared the check and "this
    /// frame is malformed" stops being spelled the same way as "no sensor".
    @Test("a quaternion this build cannot read is not a reading", arguments: [
        [] as [Double], [1, 0, 0], [1, 0, 0, 0, 0],
    ])
    func refusesAMalformedQuaternion(quaternion: [Double]) {
        #expect(reading(quaternion: quaternion) == nil)
    }

    @Test("a vector of the wrong width is not a reading either")
    func refusesAMalformedVector() {
        #expect(RobotIMUReading(
            accelerometer: [0, 9.81],
            gyroscope: [0, 0, 0],
            quaternion: [1, 0, 0, 0],
            temperatureCelsius: 31.5
        ) == nil)
    }
}
