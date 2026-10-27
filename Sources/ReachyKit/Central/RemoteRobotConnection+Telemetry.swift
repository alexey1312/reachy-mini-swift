import Foundation

/// `get_telemetry` and `set_telemetry`, from daemon 1.13.0: the same choice as
/// `GET/PUT /api/telemetry`, for a client that reaches the robot only over the
/// data channel (pollen-robotics/reachy_mini#1487).
///
/// `RobotSession.canShareTelemetry` keeps an older relayed daemon from being
/// asked: it answers an unknown command with an `error` that names no command, so
/// the reply would match no waiter.
extension RemoteRobotConnection: RobotTelemetryClient {
    public func telemetry() async throws -> RobotTelemetry? {
        try await control.perform("get_telemetry", expecting: TelemetryReply.self).telemetry()
    }

    public func setTelemetry(enabled: Bool) async throws -> RobotTelemetry {
        try await control.perform(
            "set_telemetry",
            payload: ["enabled": .bool(enabled)],
            expecting: TelemetryReply.self
        ).telemetry()
    }

    /// `{command, status, enabled, disabled_by_env}`. A write the daemon could not
    /// save answers `status: "error"` with the choice it still holds, so the
    /// status is read rather than assumed.
    private struct TelemetryReply: Decodable {
        let status: String?
        let enabled: Bool
        let disabledByEnv: Bool

        private enum CodingKeys: String, CodingKey {
            case status, enabled
            case disabledByEnv = "disabled_by_env"
        }

        func telemetry() throws -> RobotTelemetry {
            guard status != "error" else {
                throw RemoteControlChannel.Failure.robot("The robot could not save this setting.")
            }
            return RobotTelemetry(isEnabled: enabled, isDisabledByEnvironment: disabledByEnv)
        }
    }
}
