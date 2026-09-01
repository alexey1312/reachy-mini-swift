import Foundation

/// The robot's inertial reading, over the relay.
public extension RemoteRobotConnection {
    /// `get_imu` is answered with the same `imu_data` frame the robot publishes
    /// unasked, so the correlation is by type rather than by an echoed command —
    /// see ``RemoteControlChannel/Correlation/typed(_:)``. A relayed robot is a
    /// Wireless one by construction, so unlike the HTTP route this has no IMU-less
    /// case to report.
    func imuReading() async throws -> RobotIMUReading? {
        let reply = try await control.perform(
            "get_imu",
            correlation: .typed("imu_data"),
            expecting: IMUReply.self
        )
        return RobotIMUReading(
            accelerometer: reply.accelerometer,
            gyroscope: reply.gyroscope,
            quaternion: reply.quaternion,
            temperatureCelsius: reply.temperature
        )
    }
}

/// `ImuDataMsg` flat, as the daemon sends it — the `type` is the correlation rather
/// than payload, so it is not read here.
private struct IMUReply: Decodable {
    let accelerometer: [Double]
    let gyroscope: [Double]
    let quaternion: [Double]
    let temperature: Double
}
