import Foundation

/// The robot's inertial reading, over the relay.
public extension RemoteRobotConnection {
    /// `get_imu` echoes its command name and carries the reading under `imu` —
    /// `null` where there is none, which on a relayed robot means a cached reading
    /// that has gone stale. Upstream's own tests pin that shape
    /// (`test_get_imu_with_reading`, `test_get_imu_without_imu`). The robot's
    /// unsolicited 50 Hz `imu_data` broadcast is a different frame: it names a
    /// `type`, carries no `command`, and never answers the question.
    func imuReading() async throws -> RobotIMUReading? {
        let reply = try await control.perform("get_imu", expecting: IMUReply.self)
        guard let reading = reply.imu else { return nil }
        return RobotIMUReading(
            accelerometer: reading.accelerometer,
            gyroscope: reading.gyroscope,
            quaternion: reading.quaternion,
            temperatureCelsius: reading.temperature
        )
    }
}

/// `{"command": "get_imu", "imu": {…} | null}` — the reading is `ImuDataMsg`
/// dumped without its `type`.
private struct IMUReply: Decodable {
    struct Reading: Decodable {
        let accelerometer: [Double]
        let gyroscope: [Double]
        let quaternion: [Double]
        let temperature: Double
    }

    let imu: Reading?
}
