import Foundation

/// `GET/PUT /api/telemetry`, from daemon 1.13.0.
extension RobotConnection: RobotTelemetryClient {
    public func telemetry() async throws -> RobotTelemetry? {
        switch try await client.getTelemetryApiTelemetryGet() {
        case let .ok(response):
            try RobotTelemetry(response.body.json)
        // The route postdates the robot: nothing to show, nothing gone wrong. A case
        // of its own, because swiftformat's `redundantReturn` rewrote a `return nil`
        // inside an `if` here into a bare `nil` that does not compile.
        case .undocumented(404, _):
            nil
        case let .undocumented(statusCode, payload):
            throw await ReachyKitError.fromStatusCode(statusCode, detail: Self.detail(of: payload))
        }
    }

    /// A 500 with "Could not save setting: …" when the daemon cannot write its
    /// config file; that sentence is passed on.
    public func setTelemetry(enabled: Bool) async throws -> RobotTelemetry {
        switch try await client.setTelemetryApiTelemetryPut(body: .json(.init(enabled: enabled))) {
        case let .ok(response):
            try RobotTelemetry(response.body.json)
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, payload):
            if statusCode == 404 {
                throw ReachyKitError.telemetryUnavailable
            }
            throw await ReachyKitError.fromStatusCode(statusCode, detail: Self.detail(of: payload))
        }
    }
}

extension RobotTelemetry {
    init(_ status: Components.Schemas.TelemetryStatus) {
        self.init(isEnabled: status.enabled, isDisabledByEnvironment: status.disabledByEnv)
    }
}
