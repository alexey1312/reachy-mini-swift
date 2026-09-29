import Foundation
import OpenAPIRuntime

public extension RobotConnection {
    /// The robot's inertial reading, or nil where there is none to read.
    ///
    /// Two answers mean "none", and neither is a failure:
    ///
    /// - `200 null` — a Lite unit or the simulator, which have no BMI088, or a
    ///   Wireless robot whose cached reading has gone stale. The generated client
    ///   decodes the body *inside* the call and cannot fit `null` into a
    ///   required-field struct, so that null arrives as a thrown decoding error at
    ///   the top of the document — and only that error is forgiven.
    /// - `404` — a daemon before 1.11.0, which already answers `get_imu` on the
    ///   relay but has no REST route for it (measured on a 1.10.0 Wireless, see
    ///   `docs/research/webrtc.md`).
    ///
    /// Everything else escapes. A 503 from a restarting daemon read as "none" would
    /// make a robot that has an IMU look exactly like a Lite unit that has none —
    /// on the one screen whose job is saying which.
    func imuReading() async throws -> RobotIMUReading? {
        let response: Operations.GetImuApiStateImuGet.Output
        do {
            response = try await client.getImuApiStateImuGet()
        } catch let error as ClientError where error.underlyingError.isNullDocument {
            return nil
        }
        switch response {
        case let .ok(ok):
            let payload = try ok.body.json
            return RobotIMUReading(
                accelerometer: payload.accelerometer,
                gyroscope: payload.gyroscope,
                quaternion: payload.quaternion,
                temperatureCelsius: payload.temperature
            )
        case .undocumented(statusCode: 404, _):
            return nil
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }
}

private extension Error {
    /// `null` where the schema wants an object, at the very top of the document —
    /// the one decoding failure a nullable route that the spec normalised to a
    /// required object is expected to raise. Anything deeper is a malformed reading
    /// and stays an error.
    var isNullDocument: Bool {
        guard let decoding = self as? DecodingError,
              case let .valueNotFound(_, context) = decoding
        else { return false }
        return context.codingPath.isEmpty
    }
}
