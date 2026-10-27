#if DEBUG
    import Foundation

    /// Both preview clients speak a 1.13 robot's telemetry, so a preview session
    /// answers `canShareTelemetry` the way a real one does. Settings draws the
    /// switch only after a read, and no capture reads, so no existing reference
    /// gains it; the `Usage data —` previews hand the section a model instead.
    extension PreviewRobotClient: RobotTelemetryClient {
        public func telemetry() async throws -> RobotTelemetry? {
            RobotTelemetry(isEnabled: true, isDisabledByEnvironment: false)
        }

        public func setTelemetry(enabled: Bool) async throws -> RobotTelemetry {
            RobotTelemetry(isEnabled: enabled, isDisabledByEnvironment: false)
        }
    }

    extension PreviewRemoteRobotClient: RobotTelemetryClient {
        public func telemetry() async throws -> RobotTelemetry? {
            RobotTelemetry(isEnabled: true, isDisabledByEnvironment: false)
        }

        public func setTelemetry(enabled: Bool) async throws -> RobotTelemetry {
            RobotTelemetry(isEnabled: enabled, isDisabledByEnvironment: false)
        }
    }
#endif
